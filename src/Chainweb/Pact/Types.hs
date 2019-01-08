{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module: Chainweb.Pact.Types
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Pact Types module for Chainweb
module Chainweb.Pact.Types
    ( Block(..)
    , bBlockHeight
    , bHash
    , bParentHash
    , bTransactions
    , PactDbStatePersist(..)
    , pdbspRestoreFile
    , pdbspPactDbState
    , PactT
    , Transaction(..)
    , tCmd
    , tTxId
    , TransactionCriteria(..)
    , TransactionOutput(..)
    , module Chainweb.Pact.Backend.Types
    ) where

import qualified Chainweb.BlockHeader as C
import Chainweb.Pact.Backend.Types

import qualified Pact.Types.Command as P
import qualified Pact.Types.Runtime as P

import Control.Lens
import Control.Monad.Trans.RWS.Lazy
import Data.ByteString (ByteString)
import GHC.Word (Word64)

data Transaction = Transaction
    { _tTxId :: Word64
    , _tCmd :: P.Command ByteString
    }

makeLenses ''Transaction

newtype TransactionOutput = TransactionOutput
    { _getCommandResult :: P.CommandResult
    }

data Block = Block
    { _bHash :: Maybe P.Hash
    , _bParentHash :: P.Hash
    , _bBlockHeight :: C.BlockHeight
    , _bTransactions :: [(Transaction, TransactionOutput)]
    }

makeLenses ''Block

data PactDbStatePersist = PactDbStatePersist
    { _pdbspRestoreFile :: Maybe FilePath
    , _pdbspPactDbState :: PactDbState
    }

makeLenses ''PactDbStatePersist

type PactT a = RWST CheckpointEnv' () PactDbState IO a

data TransactionCriteria =
    TransactionCriteria
