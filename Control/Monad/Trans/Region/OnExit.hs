-------------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Trans.Region.OnExit
-- Copyright   :  (c) 2009-2011 Bas van Dijk
-- License     :  BSD3 (see the file LICENSE)
-- Maintainer  :  Bas van Dijk <v.dijk.bas@gmail.com>
--
-- This module is not intended for end-users. It should only be used by library
-- authors wishing to extend this @regions@ library.
--
--------------------------------------------------------------------------------

module Control.Monad.Trans.Region.OnExit
    ( FinalizerHandle
    , onExit
    ) where

import Control.Monad.Trans.Region.Internal
    ( FinalizerHandle
    , onExit
    )
