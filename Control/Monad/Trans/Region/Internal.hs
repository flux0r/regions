{-# LANGUAGE UnicodeSyntax
           , NoImplicitPrelude
           , GeneralizedNewtypeDeriving
           , RankNTypes
           , ScopedTypeVariables
           , KindSignatures
           , TypeFamilies
           , MultiParamTypeClasses
           , FunctionalDependencies
           , UndecidableInstances
           , FlexibleInstances
           , OverlappingInstances
           , NamedFieldPuns
           , ExistentialQuantification
           , ViewPatterns
  #-}

-------------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Trans.Region.Internal
-- Copyright   :  (c) 2009 Bas van Dijk
-- License     :  BSD3 (see the file LICENSE)
-- Maintainer  :  Bas van Dijk <v.dijk.bas@gmail.com>
--
-- This modules implements a technique called /"Lightweight monadic regions"/
-- invented by Oleg Kiselyov and Chung-chieh Shan
--
-- See: <http://okmij.org/ftp/Haskell/regions.html#light-weight>
--
-- This is an internal module not intended to be exported.
-- Use @Control.Monad.Trans.Region@  or @Control.Monad.Trans.Region.Unsafe@.
--
--------------------------------------------------------------------------------

module Control.Monad.Trans.Region.Internal
    ( -- * Scarce resources
      Resource
    , Handle
    , openResource
    , closeResource

      -- * Regions
    , RegionT

      -- * Running regions
    , runRegionT

    , TopRegion
    , runTopRegion

    , forkTopRegion

      -- * Opening resources
    , RegionalHandle

    , internalHandle
    , mapInternalHandle

    , open
    , with

      -- * Duplication
    , Dup
    , dup

      -- * Handy functions for writing monadic instances
    , liftCallCC
    , mapRegionT
    , liftCatch

      -- * Parent/child relationship between regions.
    , ParentOf
    ) where


--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from base:
import Prelude             ( succ, pred, fromInteger )
import Control.Concurrent  ( forkIO, ThreadId )
import Control.Applicative ( Applicative, Alternative )
import Control.Monad       ( Monad, return, (>>=), fail
                           , (>>), when, liftM2, mapM_, forM_
                           , Functor
                           , MonadPlus
                           )
import Control.Monad.Fix   ( MonadFix )
import System.IO           ( IO )
import Data.Function       ( ($) )
import Data.Int            ( Int )
import Data.IORef          ( IORef, newIORef
                           , readIORef, modifyIORef, atomicModifyIORef
                           )
-- from MonadCatchIO-transformers:
import Control.Monad.CatchIO ( MonadCatchIO, block, bracket )

-- from transformers:
import Control.Monad.Trans   ( MonadTrans, lift, MonadIO, liftIO )

import qualified Control.Monad.Trans.Reader as R ( liftCallCC, liftCatch )
import           Control.Monad.Trans.Reader      ( ReaderT
                                                 , ask
                                                 , runReaderT, mapReaderT
                                                 )
-- from base-unicode-symbols:
import Data.Eq.Unicode       ( (≡) )
import Data.Function.Unicode ( (∘) )


--------------------------------------------------------------------------------
-- * Scarce resources
--------------------------------------------------------------------------------

{-| Class of /scarce/ resources. A scarce resource is a resource that only one
user can use at a time. (like a file, memory pointer or USB device for
example).

Because of the scarcity, these resources need to be /opened/ to grant temporary
sole access to the resource. When the resource is no longer needed it should be
/closed/ a.s.a.p to grant others access to the resource.
-}
class Resource resource where
    data Handle resource ∷ *

    openResource  ∷ resource → IO (Handle resource)
    closeResource ∷ Handle resource → IO ()


--------------------------------------------------------------------------------
-- * Regions
--------------------------------------------------------------------------------

{-| A monad transformer in which scarce resources can be opened
which are automatically closed when the region terminates.

Note that regions can be nested. @pr@ (for parent region) is a monad which is
usually the region which is running this region. However when you are running a
'TopRegion' the parent region will be 'IO'.
-}
newtype RegionT s (pr ∷ * → *) α = RegionT
    { unRegionT ∷ ReaderT (IORef [AnyRegionalHandle]) pr α }

    deriving ( Functor
             , Applicative
             , Alternative
             , Monad
             , MonadPlus
             , MonadFix
             , MonadTrans
             , MonadIO
             , MonadCatchIO
             )

-- | An internally used datatype which adds an existential wrapper around a
-- 'RegionalHandle' to hide the @resource@ type.
--
-- If the @resource@ type is not hidden, regions must be parameterized by
-- it. This is undesirable because then only one type of resource can be opened
-- in a region. The following allows all types of resources to be opened in a
-- single region as long as they have an instance for 'Resource'.
data AnyRegionalHandle = ∀ resource (r ∷ * → *). Resource resource
                       ⇒ Any (RegionalHandle resource r)

-- | A handle to an opened resource parameterized by the @resource@ and the
-- region @r@ in which it was created.
data RegionalHandle resource (r ∷ * → *) = RegionalHandle
    { {-| Get the internal handle from the given regional handle.

      /Warning:/ This function should not be exported to or used by end-users
      because it allows them to close the handle manually, which will defeat the
      safety-guarantees that this package provides!

      /Tip:/ If you enable the @ViewPatterns@ language extension you can use
      @internalHandle@ as a view-pattern as in the following example from the
      @usb-safe@ package:

      @
      resetDevice :: (pr \`ParentOf\` cr, MonadIO cr)
                  -> RegionalHandle USB.Device pr -> cr ()
      resetDevice (internalHandle -> (DeviceHandle ...)) = ...
      @
      -}
      internalHandle ∷ Handle resource

      {-| Get the reference count from the given regional handle.

      Normally a handle should be closed when its originating region
      terminates. There are two exceptions to this rule:

      * When a handle is /duplicated/ to a parent region using 'dup'
        it should only be closed when the parent region terminates.

      * When a region is executed in a new thread using 'forkTopRegion' all
        handles that can be referenced in the originating region should also be
        referencable in the new forked region. Therefore those handles should only be
        closed when the originating region or the new forked region terminates,
        whichever comes /last/.

      To implement this behaviour, handles are reference counted.
      The reference count is:

       * Initialized at 1 in 'open'.

       * Incremented in 'dup' and 'forkTopRegion'.

       * Decremented on termination of 'runRegionWith'
         (which is called by 'runRegionT' and 'forkTopRegion').

      Only when the reference count reaches 0 will the resource actually be
      closed.
      -}
    , refCntIORef ∷ IORef Int
    }

-- | Modify the internal handle from the given regional handle.
mapInternalHandle ∷ (Handle resource1 → Handle resource2)
                  → (RegionalHandle resource1 r → RegionalHandle resource2 r)
mapInternalHandle f rh = rh { internalHandle = f $ internalHandle rh }

{-| Internally used function that atomically decrements the reference count that
is stored in the given @IORef@. The function returns the decremented reference
count.
-}
decrement ∷ IORef Int → IO Int
decrement ioRef = atomicModifyIORef ioRef $ \refCnt →
                  let predRefCnt = pred refCnt
                  in (predRefCnt, predRefCnt)

-- | Internally used function that atomically increments the reference count that
-- is stored in the given @IORef@.
increment ∷ IORef Int → IO ()
increment ioRef = atomicModifyIORef ioRef $ \refCnt →
                  (succ refCnt, ())


--------------------------------------------------------------------------------
-- * Running regions
--------------------------------------------------------------------------------

{-| Execute a region inside its parent region @pr@.

All resources which have been opened in the given region using 'open', and which
haven't been duplicated using 'dup', will be closed on exit from this function
wether by normal termination or by raising an exception.

Also all resources which have been duplicated to this region from a child region
are closed on exit if they haven't been duplicated themselves.

Note the type variable @s@ of the region wich is only quantified over the region
itself. This ensures that /all/ values, having a type containing @s@, can /not/
be returned from this function. (Note the similarity with the @ST@ monad.)

An example of such a value is a 'RegionalHandle'. Regional handles are created by
opening a resource in a region using 'open'. Regional handles are parameterized by
the region in which they were created. So regional handles have this @s@ in their
type. This ensures that these regional handles, which may have been closed on exit
from this function, can't be returned from this function. This ensures you can
never do any IO with a closed regional handle.

Note that it is possible to run a region inside another region.
-}
runRegionT ∷ MonadCatchIO pr ⇒ (∀ s. RegionT s pr α) → pr α
runRegionT m = runRegionWith [] m

{-| A region which has 'IO' as its parent region which enables it to be:

 * directly executed in 'IO' by 'runTopRegion',

 * concurrently executed in a new thread by 'forkTopRegion'.
-}
type TopRegion s = RegionT s IO

{-| Convenience funtion for running a /top-level/ region in 'IO'.

Note that: @runTopRegion = 'runRegionT'@
-}
runTopRegion ∷ (∀ s. TopRegion s α) → IO α
runTopRegion = runRegionT

{-| Return a region which executes the given /top-level/ region in a new thread.

Note that the forked region has the same type variable @s@ as the resulting
region. This means that all values which can be referenced in the resulting
region (like 'RegionalHandle's for example) can also be referenced in the forked
region.

For example the following is allowed:

@
runRegionT $ do
  regionalHndl <- open resource
  threadId <- forkTopRegion $ doSomethingWith regionalHndl
  doSomethingElseWith regionalHndl
@

Note that the @regionalHndl@ and all other resources opened in the current
thread are closed only when the current thread or the forked thread terminates
whichever comes /last/.
-}
forkTopRegion ∷ MonadIO pr ⇒ TopRegion s () → RegionT s pr ThreadId
forkTopRegion m = RegionT $ do
  anyRegionalHandlesIORef ← ask
  liftIO $ do
    anyRegionalHandles ← readIORef anyRegionalHandlesIORef
    block $ do
      -- Increment the reference count of each opened resource so that
      -- when the current region terminates the resources will stay
      -- open in the, to be created, thread:
      forM_ anyRegionalHandles $ \(Any (RegionalHandle {refCntIORef})) →
        increment refCntIORef

      -- Fork a new thread that will concurrently run the given region
      -- on the opened resources of the current region:

      -- (Note that if asynchronous exceptions weren't blocked and an
      -- exception is asynchronously thrown to this thread at this
      -- point after incrementing the opened resource's reference
      -- count but before forking of a new thread that will run the
      -- given region on the opened resources, all the opened
      -- resources will never get closed, because their reference
      -- count will never reach 0!)
      forkIO $ runRegionWith anyRegionalHandles m

-- | Internally used function that actually runs the region on the given list of
-- opened resources.
runRegionWith ∷ ∀ s pr α. MonadCatchIO pr
              ⇒ [AnyRegionalHandle] → RegionT s pr α → pr α
runRegionWith anyRegionalHandles m =
    bracket
      -- Create a new IORef containing the initial opened resources:
      (liftIO $ newIORef anyRegionalHandles)

      -- When the computation terminates the IORef contains a list of all
      -- resources which have been opened or duplicated to this region. We
      -- should decrement the reference count of each opened resource and
      -- actually close the resource when it reaches 0:
      (\anyRegionalHandlesIORef → liftIO
                                $ readIORef anyRegionalHandlesIORef >>= mapM_ end)

      (runReaderT $ unRegionT m)
    where
      end (Any (RegionalHandle {internalHandle, refCntIORef})) = do
        refCnt ← decrement refCntIORef
        when (refCnt ≡ 0) $ closeResource internalHandle


--------------------------------------------------------------------------------
-- * Opening resources
--------------------------------------------------------------------------------

{-| Open the given resource in a region yielding a regional handle to it.

Note that the returned regional handle is parameterized by the region in which
it was created. This ensures that regional handles can never escape their
region. And it also allows operations on regional handles to be executed in a
child region of the region in which the regional handle was created.

Note that if you /do/ wish to return a regional handle from the region in which
it was created you have to /duplicate/ the handle by applying 'dup' to it.
-}
open ∷ (Resource resource, MonadCatchIO pr)
     ⇒ resource
     → RegionT s pr
         (RegionalHandle resource (RegionT s pr))
open resource = block $ do
  -- Create a new regional handle by actually opening the resource and
  -- intializing the reference count to 1:
  regionalHandle ← liftIO $ liftM2 RegionalHandle (openResource resource)
                                                  (newIORef 1)

  -- The following registers the just opened resource so that it will get closed
  -- eventually:

  -- (Note that if asynchronous exceptions weren't blocked and an exception is
  -- asynchronously thrown to this thread at this point after opening the
  -- resource and initializing its reference count to 1 but before registering
  -- the resource, the opened resource will never get closed, because its
  -- reference count will never reach 0!)
  register regionalHandle

  -- Return the regional handle of which the type will be parameterized by this
  -- region:
  return regionalHandle

{-| A convenience function which opens the given resource, applies the given
continuation function to the resulting regional handle and runs the resulting
region.

Note that: @with resource f = 'runRegionT' ('open' resource '>>=' f)@.
-}
with ∷ (Resource resource, MonadCatchIO pr)
     ⇒ resource
     → (∀ s. RegionalHandle resource (RegionT s pr) → RegionT s pr α)
     → pr α
with resource f = runRegionT $ open resource >>= f

-- | Internally used function to /register/ the given opened resource by
-- /consing/ it to the list of opened resources of the region.
register ∷ (Resource resource, MonadIO pr)
         ⇒ RegionalHandle resource (RegionT s pr)
         → RegionT s pr ()
register regionalHandle = RegionT $ do
  anyRegionalHandlesIORef ← ask
  liftIO $ modifyIORef anyRegionalHandlesIORef (Any regionalHandle:)


--------------------------------------------------------------------------------
-- * Duplication
--------------------------------------------------------------------------------

{-| Duplicate an @&#945;@ in the parent region. This @&#945;@ will usually be a
@(@'RegionalHandle'@ resource)@ but it can be any value \"derived\" from this
regional handle.

For example, suppose you run the following region:

@
runRegionT $ do
@

Inside this region you run a nested /child/ region like:

@
    r1hDup <- runRegionT $ do
@

Now in this child region you open the resource @r1@:

@
        r1h <- open r1
@

...yielding the regional handle @r1h@. Note that:

@r1h :: RegionalHandle resource (RegionT cs (RegionT ps ppr))@

where @cs@ is bound by the inner (child) @runRegionT@ and @ps@ is
bound by the outer (parent) @runRegionT@.

Suppose you want to use the resulting regional handle @r1h@ in the /parent/
region. You can't simply @return r1h@ because then the type variable @cs@,
escapes the inner region.

However, if you duplicate the regional handle you can safely return it.

@
        r1hDup <- dup r1h
        return r1hDup
@

Note that @r1hDup :: RegionalHandle resource (RegionT ps ppr)@

Back in the parent region you can safely operate on @r1hDup@.
-}
class Dup α where
    dup ∷ MonadCatchIO ppr
        ⇒ α (RegionT cs (RegionT ps ppr))
        → RegionT cs (RegionT ps ppr)
              (α (RegionT ps ppr))

instance Resource resource ⇒ Dup (RegionalHandle resource) where
    dup (RegionalHandle {internalHandle, refCntIORef}) = block $ do
      -- Increment the reference count of the given opened resource so that it
      -- won't get closed when the current region terminates:
      liftIO $ increment refCntIORef

      -- The following registers the opened resource in the parent region so
      -- that it will get closed eventually:

      let duppedRegionalHandle = RegionalHandle internalHandle refCntIORef

      -- (Note that if asynchronous exceptions weren't blocked and an exception
      -- is asynchronously thrown to this thread at this point after
      -- incrementing the opened resource's reference count but before
      -- registering it in the parent, the opened resource will never get
      -- closed, because its reference count will never reach 0!)
      lift $ register duppedRegionalHandle

      -- Return a new regional handle containing the given opened resource. The
      -- type of the regional handle will be parameterized by the parent of this
      -- region.
      return duppedRegionalHandle


--------------------------------------------------------------------------------
-- * Handy functions for writing monadic instances
--------------------------------------------------------------------------------

-- | Lift a @callCC@ operation to the new monad.
liftCallCC ∷ (((α → pr β) → pr α) → pr α)
           → (((α → RegionT s pr β) → RegionT s pr α) → RegionT s pr α)
liftCallCC callCC f = RegionT $ R.liftCallCC callCC $ unRegionT ∘ f ∘ (RegionT ∘)

-- | Transform the computation inside a region.
mapRegionT ∷ (m α → n β) → RegionT s m α → RegionT s n β
mapRegionT f = RegionT ∘ mapReaderT f ∘ unRegionT

-- | Lift a 'catchError' operation to the new monad.
liftCatch ∷ (pr α → (e → pr α) → pr α) -- ^ @catch@ on the argument monad.
          → RegionT s pr α             -- ^ Computation to attempt.
          → (e → RegionT s pr α)       -- ^ Exception handler.
          → RegionT s pr α
liftCatch f m h = RegionT $ R.liftCatch f (unRegionT m) (unRegionT ∘ h)


--------------------------------------------------------------------------------
-- * Parent/child relationship between regions.
--------------------------------------------------------------------------------

{-| The @ParentOf@ class declares the parent/child relationship between regions.

A region is the parent of another region if they're either equivalent like:

@
RegionT ps pr  \`ParentOf\`  RegionT ps pr
@

or if it is the parent of the parent of the child like:

@
RegionT ps ppr \`ParentOf\` RegionT cs
                              (RegionT pcs
                                (RegionT ppcs
                                  (RegionT ps ppr)))
@
-}
class (Monad pr, Monad cr) ⇒ pr `ParentOf` cr

instance Monad r ⇒ ParentOf r r

instance ( Monad cr
         , cr `TypeCast2` RegionT s pcr
         , pr `ParentOf` pcr
         )
         ⇒ ParentOf pr cr


--------------------------------------------------------------------------------
-- Type casting
--------------------------------------------------------------------------------

class TypeCast2     (a ∷ * → *) (b ∷ * → *) |   a → b,   b → a
class TypeCast2'  t (a ∷ * → *) (b ∷ * → *) | t a → b, t b → a
class TypeCast2'' t (a ∷ * → *) (b ∷ * → *) | t a → b, t b → a

instance TypeCast2'  () a b ⇒ TypeCast2    a b
instance TypeCast2'' t  a b ⇒ TypeCast2' t a b
instance TypeCast2'' () a a


-- The End ---------------------------------------------------------------------
