{-# LANGUAGE NoImplicitPrelude, GeneralizedNewtypeDeriving,
             KindSignatures, RankNTypes, ScopedTypeVariables,
             MultiParamTypeClasses, FlexibleInstances,
             UndecidableInstances, EmptyDataDecls #-}

-- {-# LANGUAGE CPP                        -- For portability.
--            , UnicodeSyntax              -- Makes it look so nice.
--            , NoImplicitPrelude          -- I like to be fully explicit.
--            , GeneralizedNewtypeDeriving -- I'm lazy.
--            , RankNTypes                 -- Provides the essential type-safety.
--            , KindSignatures             -- To help the type-checker.
--            , EmptyDataDecls             -- For the RootRegion type.
--            , MultiParamTypeClasses      -- For the AncestorRegion class.
--            , UndecidableInstances       -- For the AncestorRegion instances.
--            , FlexibleInstances          -- ,,          ,,          ,,
--            , OverlappingInstances       -- ,,          ,,          ,,
--            , FlexibleContexts           -- For unsafeLiftControl
--   #-}

-------------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Trans.Region.Internal
-- Copyright   :  (c) 2009-2011 Bas van Dijk
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
    ( -- * Regions
      RegionT

      -- * Registering finalizers
    , FinalizerHandle
    , onExit

      -- * Running regions
    , runRegionT

      -- * Duplication
    , Dup (dup)

      -- * Ancestor relation between regions
    , AncestorRegion

      -- * Special regions
      -- ** The root region
    , RootRegion

      -- ** Local regions
    , LocalRegion, Local, unsafeStripLocal

      -- * MonadTransControl & MonadControlIO
--     , RegionControlIO, unsafeLiftControlIO
--     , unsafeLiftControl
--     , unsafeControlIO
--     , unsafeLiftIOOp
--     , unsafeLiftIOOp_
-- 
--       -- * Utilities for writing monadic instances
--     , liftCallCC
--     , mapRegionT
--     , liftCatch
    ) where


--------------------------------------------------------------------------------
-- Imports
--------------------------------------------------------------------------------

-- from base:
import Prelude ((-), (+), seq)
import Control.Applicative (Applicative, Alternative)
import Control.Category ((.), id)
import Control.Exception (Exception)
import Control.Monad (Monad, MonadPlus, return, forM_, when)
import Control.Monad.Fix (MonadFix)
import Data.Eq ((==))
import Data.Function (($))
import Data.Functor (Functor)
import Data.Int (Int)
import System.IO (IO)

import qualified Control.Exception as E

-- import Control.Exception   ( bracket )
-- import System.IO           ( IO )
-- import Data.Function       ( ($) )
-- import Data.Functor        ( Functor )
-- import Data.Int            ( Int )
-- import Data.IORef          ( IORef, newIORef
--                            , readIORef, modifyIORef, atomicModifyIORef
--                            )
import Data.IORef
-- #if __GLASGOW_HASKELL__ < 700
-- import Prelude             ( fromInteger )
-- import Control.Monad       ( (>>=), (>>), fail )
-- #endif
-- 
-- -- from monad-control:
-- import Control.Monad.Trans.Control ( Run, RunInBase, liftControl )
-- import Control.Monad.IO.Control    ( MonadControlIO, liftControlIO )
-- 
-- from transformers:
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.IO.Class (MonadIO, liftIO)
-- import Control.Monad.Trans.Class ( MonadTrans, lift )
-- import Control.Monad.IO.Class    ( MonadIO, liftIO )
-- 
-- import qualified Control.Monad.Trans.Reader as R ( liftCallCC, liftCatch )
-- import Control.Monad.Trans.Reader ( ReaderT(ReaderT), runReaderT, mapReaderT )
import Control.Monad.Reader (ReaderT (ReaderT), runReaderT)
-- 
-- -- from base-unicode-symbols:
-- import Data.Eq.Unicode       ( (≡) )
-- import Data.Function.Unicode ( (∘) )
-- 
-- -- Handling the new asynchronous exceptions API in base-4.3:
-- #if MIN_VERSION_base(4,3,0)
-- import Control.Exception ( mask_ )
-- #else
-- import Control.Exception ( block )
-- mask_ ∷ IO α → IO α
-- mask_ = block
-- #endif



------------------------------------------------------------------------------
-- * Regions                                                                -- 
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | A monad transformer in which scarce resources can be opened. When the
-- region terminates, all opened resources will be closed automatically. It's
-- a type error to return an opened resource from the region; input-output
-- with closed resources is impossible.

newtype RegionT s p a = RegionT (ReaderT (IORef [RefCountedFinalizer]) p a)
    deriving ( Functor
             , Applicative
             , Alternative
             , Monad
             , MonadPlus
             , MonadFix
             , MonadTrans
             , MonadIO
             )

unRegionT :: RegionT s p a -> ReaderT (IORef [RefCountedFinalizer]) p a
unRegionT (RegionT r) = r


------------------------------------------------------------------------------
-- | An 'IO' computation that closes or finalizes a resource is paired with
-- its reference count, which defines how many times it has been registered in
-- some region.

data RefCountedFinalizer = RefCountedFinalizer !(IO ()) !(IORef Int)



------------------------------------------------------------------------------
-- * Registering finalizers                                                 --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | A handle to a finalizer that allows you to duplicate it to a parent
-- region using 'dup'.
--
-- Duplicating a finalizer means that instead of it being performed when the
-- current region terminates it is performed when the parent region
-- terminates.

newtype FinalizerHandle (r :: * -> *) = FinalizerHandle RefCountedFinalizer


------------------------------------------------------------------------------
-- | Register the finalizer in the region. When the region terminates all
-- registered finalizers will be perfomed if they're not duplicated to a
-- parent region.
-- 
-- Note that finalizers are run in LIFO order (Last In First Out). So
-- executing the following:
-- 
-- @
-- runRegionT $ do
--   _ <- onExit $ putStrLn \"finalizer 1\"
--   _ <- onExit $ putStrLn \"finalizer 2\"
--   return ()
-- @
-- 
-- yields:
-- 
-- @
-- finalizer 2
-- finalizer 1
-- @

onExit :: MonadIO p => IO () -> RegionT s p (FinalizerHandle (RegionT s p))
onExit finalizer = RegionT $ ReaderT $ \hsIORef -> liftIO $ do
    refCntIORef <- newIORef 1
    let h = RefCountedFinalizer finalizer refCntIORef
    modifyIORef hsIORef (h:)
    return $ FinalizerHandle h



------------------------------------------------------------------------------
-- * Running regions                                                        --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | Execute a region inside its parent region @p@.
-- 
-- All resources which have been opened in the given region and which haven't
-- been duplicated using 'dup', will be closed on exit from this function
-- whether by normal termination or by raising an exception.
-- 
-- Also, all resources which have been duplicated to this region from a child
-- region are closed on exit if they haven't been duplicated themselves.
-- 
-- Note the type variable @s@ of the region; it is only quantified over the
-- region itself. This ensures that /no/ values having a type containing
-- @s@ can be returned from this function. (In this way, RegionT is similar to
-- the @ST@ monad.)
-- 
-- It is possible to run a region inside another region.

runRegionT :: RMonadIO p => (forall s. RegionT s p a) -> p a
runRegionT r = (bracket (lift_io before) (lift_io . after)) thing
  where
    before = newIORef []
    thing hsIORef = runReaderT (unRegionT r) hsIORef
    after hsIORef = do
        hs' <- readIORef hsIORef
        forM_ hs' $ \(RefCountedFinalizer finalizer refCntIORef) -> do
            refCnt <- decrement refCntIORef
            when (refCnt == 0) finalizer


------------------------------------------------------------------------------
decrement :: IORef Int -> IO Int
decrement x = atomicModifyIORef x $ \ref_cnt0 ->
    let ref_cnt1 = ref_cnt0 - 1
    in  (ref_cnt1, ref_cnt1)


class Monad p => RMonadIO p where
    bracket :: p a -> (a -> p b) -> (a -> p c) -> p c
    catch   :: Exception e => p a -> (e -> p a) -> p a
    lift_io :: IO a -> p a


instance RMonadIO IO where
    bracket = E.bracket
    catch   = E.catch
    lift_io = id


instance RMonadIO m => RMonadIO (ReaderT r m) where
    bracket before after during = ReaderT $ \r ->
        let runner :: RMonadIO m => ReaderT r m a -> m a
            runner x = runReaderT x r
        in  bracket (runner before)
                    (runner . after)
                    (runner . during)
    catch x handler = ReaderT $ \r ->
        catch (runReaderT x r)
              (\e -> runReaderT (handler e) r)
    lift_io = lift . lift_io


instance RMonadIO m => RMonadIO (RegionT s m) where
    bracket before after during = RegionT $
        bracket (unRegionT before)
                (unRegionT . after)
                (unRegionT . during)
    catch x handler = RegionT $
        catch (unRegionT x)
              (unRegionT . handler)
    lift_io = RegionT . lift_io

------------------------------------------------------------------------------
-- * Duplication                                                            --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | Duplicate an @h@ in the parent region. This @h@ will usually be some type
-- of regional handle.
-- 
-- For example, suppose you run the following region:
-- 
-- @
-- runRegionT $ do
-- @
-- 
-- Inside this region you run a nested /child/ region like:
-- 
-- @
--     r1hDup <- runRegionT $ do
-- @
-- 
-- Now in this child region you open the resource @r1@:
-- 
-- @
--         r1h <- open r1
-- @
-- 
-- ...yielding the regional handle @r1h@. Note that:
-- 
-- @r1h :: RegionalHandle (RegionT cs (RegionT ps ppr))@
-- 
-- where @cs@ is bound by the inner (child) @runRegionT@ and @ps@ is
-- bound by the outer (parent) @runRegionT@.
-- 
-- Suppose you want to use the resulting regional handle @r1h@ in the /parent/
-- region. You can't simply @return r1h@ because then the type variable @cs@,
-- escapes the inner region.
-- 
-- However, if you duplicate the regional handle you can safely return it.
-- 
-- @
--         r1hDup <- dup r1h
--         return r1hDup
-- @
-- 
-- Note that @r1hDup :: RegionalHandle (RegionT ps ppr)@
-- 
-- Back in the parent region you can safely operate on @r1hDup@.

class Dup h where
    dup :: MonadIO p
        => h (RegionT s (RegionT s' p))
        -> RegionT s (RegionT s' p) (h (RegionT s' p))

instance Dup FinalizerHandle where
    dup = lift . copy


------------------------------------------------------------------------------
copy :: MonadIO p
     => FinalizerHandle r
     -> RegionT s p (FinalizerHandle (RegionT s p))
copy (FinalizerHandle h@(RefCountedFinalizer _ refCntIORef)) =
    RegionT $ ReaderT $ \hsIORef -> liftIO $ E.mask_ $ do
        increment refCntIORef
        modifyIORef hsIORef (h:)
        return . FinalizerHandle $ h


------------------------------------------------------------------------------
increment :: IORef Int -> IO ()
increment ioRef = do
    refCnt' <- atomicModifyIORef ioRef $ \refCnt ->
        let refCnt' = refCnt + 1
        in  (refCnt', refCnt')
    refCnt' `seq` return ()



------------------------------------------------------------------------------
-- * Ancestor relation between regions                                      --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | The @AncestorRegion@ class is used to relate the region in which
-- a resource was opened to the region in which it is used. Take the following
-- operation from the @safer-file-handles@ package as an example:
-- 
-- @hFileSize :: (pr \`AncestorRegion\` cr, MonadIO cr)
--            => RegionalFileHandle ioMode pr
--            -> cr Integer@
-- 
-- The @AncestorRegion@ class defines the parent / child relationship between
-- regions.  The constraint
-- 
-- @
--     pr \`AncestorRegion\` cr
-- @
-- 
-- is satisfied if and only if @cr@ is a sequence of zero or more \"@'RegionT'
-- s@\" (with varying @s@) applied to @pr@, in other words, if @cr@ is an
-- (improper) nested subregion of @pr@.
-- 
-- The class constraint @InternalAncestorRegion pr cr@ serves two purposes.
-- First, the instances of @InternalAncestorRegion@ do the type-level
-- recursion that implements the relation specified above. Second, since it is
-- not exported, user code cannot add new instances of 'AncestorRegion' (as
-- these would have to be made instances of @InternalAncestorRegion@, too),
-- effectively turning it into a /closed class/.
--
-- The implementation uses type-level recursion, so it is no surprise we need
-- UndecidableInstances.

class (InternalAncestorRegion p c) => AncestorRegion p c

instance (InternalAncestorRegion p c) => AncestorRegion p c

class InternalAncestorRegion (p :: * -> *) (cr :: * -> *)

instance InternalAncestorRegion (RegionT s m) (RegionT s m)

instance (InternalAncestorRegion p c)
    => InternalAncestorRegion p (RegionT s c)



------------------------------------------------------------------------------
-- * The root region                                                        --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | The @RootRegion@ is the ancestor of any region.
-- 
-- Its primary purpose is to tag regional handles which don't have an
-- associated finalizer. The standard file handles @stdin@, @stdout@, and
-- @stderr@ are good examples because they are opened at program startup time
-- and shouldn't be closed when a region terminates. Another example is the
-- @nullPtr@. It is a memory pointer that doesn't point to any allocated
-- memory and so it doesn't need to be freed.

data RootRegion a

instance InternalAncestorRegion RootRegion (RegionT s m)



------------------------------------------------------------------------------
-- * Local regions                                                          --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | A @LocalRegion@ is used to tag regional handles which are created
-- locally.
-- 
-- An example is the @LocalPtr@ in the @alloca@ function from the
-- @regional-pointers@ package:
-- 
-- @
-- alloca :: (Storable a, MonadControlIO pr)
--        => (forall sl. LocalPtr a ('LocalRegion' sl s)
--        -> RegionT ('Local' s) pr b)
--        -> RegionT s pr b
-- @
-- 
-- The finalisation of the @LocalPtr@ is not performed by the @regions@
-- library but is handled locally by @alloca@ instead.
-- 
-- The type variable @sl@, which is only quantified over the continuation,
-- ensures that locally opened resources don't escape.

data LocalRegion l s a


------------------------------------------------------------------------------
-- | A type used to tag regions in which locally created handles (handles
-- tagged with 'LocalRegion') can be used.
-- 
-- Note than any handle which is created in a @RegionT (Local s)@ can be used
-- outside that region (@RegionT s@) and vice versa (except for
-- 'LocalRegion'-tagged handles).

data Local s

instance InternalAncestorRegion (LocalRegion f s) (RegionT (Local s) m)

instance InternalAncestorRegion (RegionT s m) (RegionT (Local s) m)
instance InternalAncestorRegion (RegionT (Local s) m) (RegionT s m)


------------------------------------------------------------------------------
-- | Convert a 'Local' region to a regular region.
-- 
-- This function is unsafe because it allows you to use a 'LocalRegion'-tagged
-- handle outside its 'Local' region.

unsafeStripLocal :: RegionT (Local s) pr a -> RegionT s pr a
unsafeStripLocal = RegionT . unRegionT



------------------------------------------------------------------------------
-- * MonadTransControl & MonadControlIO                                     --
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | Regions do not have an instance for 'MonadControlIO' since that would
-- break the safety guarantees. (Think about lifting 'forkIO' into a region!)
-- 
-- However 'runRegionT' and other operations on regions do need the ability to
-- lift control operations. This is where the 'RegionControlIO' class comes
-- in. This class is identical to `MonadControlIO` but its
-- 'unsafeLiftControlIO' method is not exported by this module. So user can't
-- accidentally break the safety.
-- 
-- Note that a 'RegionT' is an instance of this class. For the rest there is a
-- catch-all @instance 'MonadControlIO' m => 'RegionControlIO' m@.

--class MonadIO m => RegionControlIO m where
    -- This function behaves like `liftControlIO` but can be used on regions.
    --
    -- You can safely use this function to lift any control operator other
    -- than `forkIO` into a region.
    --
    -- See the following why it's unsafe to lift `forkIO` using this function:
    -- <https://github.com/basvandijk/regions/wiki/unsafeLiftControlIO>
--    unsafeLiftControlIO :: (RunInBase m IO -> IO a) -> m a

-- instance RegionControlIO pr ⇒ RegionControlIO (RegionT s pr) where
--     unsafeLiftControlIO f =
--         unsafeLiftControl $ \runInPr →
--           unsafeLiftControlIO $ \runInBase →
--             let run = liftM (join ∘ lift) ∘ runInBase ∘ runInPr
--             in f run
-- 
-- instance MonadControlIO m ⇒ RegionControlIO m where
--     unsafeLiftControlIO = liftControlIO

--------------------------------------------------------------------------------

-- unsafeLiftControl ∷ Monad pr ⇒ (Run (RegionT s) → pr α) → RegionT s pr α
-- unsafeLiftControl f = RegionT $ liftControl $ \runReader →
--                         f $ liftM RegionT ∘ runReader ∘ unRegionT
-- 
-- unsafeControlIO ∷ RegionControlIO m ⇒ (RunInBase m IO → IO (m α)) → m α
-- unsafeControlIO = join ∘ unsafeLiftControlIO


------------------------------------------------------------------------------
-- unsafeLiftIOOp :: RegionControlIO m
--                => ((a -> IO (m b)) -> IO (m c))
--                -> ((a -> m b) -> m c)
-- unsafeLiftIOOp f = \g -> unsafeControlIO $ \runInIO -> f $ runInIO . g

-- unsafeLiftIOOp_ ∷ RegionControlIO m
--                 ⇒ (IO (m α) → IO (m β))
--                 → (    m α →      m β)
-- unsafeLiftIOOp_ f = \m → unsafeControlIO $ \runInIO → f $ runInIO m

--------------------------------------------------------------------------------
-- * Utilities for writing monadic instances
--------------------------------------------------------------------------------

-- | Lift a @callCC@ operation to the new monad.
-- liftCallCC ∷ (((α → pr β) → pr α) → pr α)
--            → (((α → RegionT s pr β) → RegionT s pr α) → RegionT s pr α)
-- liftCallCC callCC = \f → RegionT $ R.liftCallCC callCC $ unRegionT ∘ f ∘ (RegionT ∘)

-- | Transform the computation inside a region.
-- mapRegionT ∷ (m α → n β)
--            → (RegionT s m α → RegionT s n β)
-- mapRegionT f = RegionT ∘ mapReaderT f ∘ unRegionT

-- | Lift a @catchError@ operation to the new monad.
-- liftCatch ∷ (pr α → (e → pr α) → pr α)
--           → (RegionT s pr α → (e → RegionT s pr α) → RegionT s pr α)
-- liftCatch f = \m h → RegionT $ R.liftCatch f (unRegionT m) (unRegionT ∘ h)


-- The End ---------------------------------------------------------------------
