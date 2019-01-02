{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Test.Utils
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Test.Utils
(
-- * BlockHeaderDb Generation
  toyBlockHeaderDb
, withDB
, insertN
, prettyTree
, normalizeTree
, treeLeaves
, SparseTree(..)
, Growth(..)
, tree

-- * Test BlockHeaderDbs Configurations
, peterson
, testBlockHeaderDbs
, petersonGenesisBlockHeaderDbs
, singletonGenesisBlockHeaderDbs
, linearBlockHeaderDbs
, starBlockHeaderDbs

-- * Toy Server Interaction
, withSingleChainServer

-- * Tasty TestTree Server and ClientEnv
, testHost
, TestClientEnv(..)
, pattern BlockHeaderDbsTestClientEnv
, pattern PeerDbsTestClientEnv
, withSingleChainTestServer
, withSingleChainTestServer_
, withBlockHeaderDbsServer
, withPeerDbsServer

-- * QuickCheck Properties
, prop_iso
, prop_iso'
, prop_encodeDecodeRoundtrip

-- * Expectations
, assertExpectation
) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (bracket)
import Control.Lens (deep, filtered, (^..))
import Control.Monad.IO.Class

import Data.Bifunctor
import Data.Bytes.Get
import Data.Bytes.Put
import Data.Coerce (coerce)
import Data.Foldable
import Data.List (sortOn)
import Data.Reflection (give)
import qualified Data.Text as T
import Data.Tree
import qualified Data.Tree.Lens as LT
import Data.Word (Word64)

import qualified Network.HTTP.Client as HTTP
import Network.Socket (close)
import qualified Network.Wai as W
import qualified Network.Wai.Handler.Warp as W

import Numeric.Natural

import Servant.Client (BaseUrl(..), ClientEnv, Scheme(..), mkClientEnv)

import Test.QuickCheck
import Test.Tasty
import Test.Tasty.HUnit

import Text.Printf (printf)

-- internal modules

import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.ChainId
import Chainweb.Difficulty (HashTarget(..), targetToDifficulty)
import Chainweb.Graph
import Chainweb.RestAPI (singleChainApplication)
import Chainweb.RestAPI.NetworkID
import Chainweb.Test.Orphans.Internal ()
import Chainweb.Time
import Chainweb.TreeDB
import Chainweb.Utils
import Chainweb.Version (ChainwebVersion(..))

import qualified Data.DiGraph as G

import qualified P2P.Node.PeerDB as P2P

-- -------------------------------------------------------------------------- --
-- BlockHeaderDb Generation

-- | Initialize an length-1 `BlockHeaderDb` for testing purposes.
--
-- Borrowed from TrivialSync.hs
--
toyBlockHeaderDb :: ChainId -> IO (BlockHeader, BlockHeaderDb)
toyBlockHeaderDb cid = (g,) <$> initBlockHeaderDb (Configuration g)
  where
    graph = toChainGraph (const cid) singleton
    g = genesisBlockHeader Test graph cid

-- | Given a function that accepts a Genesis Block and
-- an initialized `BlockHeaderDb`, perform some action
-- and cleanly close the DB.
--
withDB :: ChainId -> (BlockHeader -> BlockHeaderDb -> IO ()) -> IO ()
withDB cid = bracket (toyBlockHeaderDb cid) (closeBlockHeaderDb . snd) . uncurry

-- | Populate a `TreeDb` with /n/ generated `BlockHeader`s.
--
insertN :: (TreeDb db, DbEntry db ~ BlockHeader) => Int -> BlockHeader -> db -> IO ()
insertN n g db = traverse_ (insert db) bhs
  where
    bhs = take n $ testBlockHeaders g

-- | Useful for terminal-based debugging. A @Tree BlockHeader@ can be obtained
-- from any `TreeDb` via `toTree`.
--
prettyTree :: Tree BlockHeader -> String
prettyTree = drawTree . fmap f
  where
    f h = printf "%d - %s"
              (coerce @BlockHeight @Word64 $ _blockHeight h)
              (take 12 . drop 1 . show $ _blockHash h)

normalizeTree :: Ord a => Tree a -> Tree a
normalizeTree n@(Node _ []) = n
normalizeTree (Node r f) = Node r . map normalizeTree $ sortOn rootLabel f

-- | The leaf nodes of a `Tree`.
--
treeLeaves :: Tree a -> [a]
treeLeaves t = t ^.. deep (filtered (null . subForest) . LT.root)

-- | A `Tree` which doesn't branch much. The `Arbitrary` instance of this type
-- ensures that other than the main trunk, branches won't ever be much longer
-- than 4 nodes.
--
newtype SparseTree = SparseTree { _sparseTree :: Tree BlockHeader } deriving (Show)

instance Arbitrary SparseTree where
    arbitrary = SparseTree <$> tree Randomly

-- | A specification for how the trunk of the `SparseTree` should grow.
--
data Growth = Randomly | AtMost BlockHeight deriving (Eq, Ord, Show)

-- | Randomly generate a `Tree BlockHeader` according some to `Growth` strategy.
-- The values of the tree constitute a legal chain, i.e. block heights start
-- from 0 and increment, parent hashes propagate properly, etc.
--
tree :: Growth -> Gen (Tree BlockHeader)
tree g = do
    h <- genesis
    Node h <$> forest g h

-- | Generate a sane, legal genesis block.
--
genesis :: Gen BlockHeader
genesis = do
    h <- arbitrary
    let h' = h { _blockHeight = 0 }
        hsh = computeBlockHash h'
    pure $ h' { _blockHash = hsh
              , _blockParent = hsh
              , _blockTarget = genesisBlockTarget
              , _blockWeight = 0
              }

forest :: Growth -> BlockHeader -> Gen (Forest BlockHeader)
forest Randomly h = randomTrunk h
forest g@(AtMost n) h | n < _blockHeight h = pure []
                      | otherwise = fixedTrunk g h

fixedTrunk :: Growth -> BlockHeader -> Gen (Forest BlockHeader)
fixedTrunk g h = frequency [ (1, sequenceA [fork h, trunk g h])
                           , (5, sequenceA [trunk g h]) ]

randomTrunk :: BlockHeader -> Gen (Forest BlockHeader)
randomTrunk h = frequency [ (2, pure [])
                          , (4, sequenceA [fork h, trunk Randomly h])
                          , (18, sequenceA [trunk Randomly h]) ]

fork :: BlockHeader -> Gen (Tree BlockHeader)
fork h = do
    next <- header h
    Node next <$> frequency [ (1, pure []), (1, sequenceA [fork next]) ]

trunk :: Growth -> BlockHeader -> Gen (Tree BlockHeader)
trunk g h = do
    next <- header h
    Node next <$> forest g next

-- | Generate some new `BlockHeader` based on a parent.
--
header :: BlockHeader -> Gen BlockHeader
header h = do
    nonce <- arbitrary
    payload <- arbitrary
    miner <- arbitrary
    let (Time (TimeSpan ts)) = _blockCreationTime h
        target = HashTarget maxBound
        h' = h { _blockParent = _blockHash h
               , _blockTarget = target
               , _blockPayloadHash = payload
               , _blockCreationTime = Time . TimeSpan $ ts + 10000000  -- 10 seconds
               , _blockNonce = nonce
               , _blockMiner = miner
               , _blockWeight = BlockWeight (targetToDifficulty target) + _blockWeight h
               , _blockHeight = succ $ _blockHeight h }
    pure $ h' { _blockHash = computeBlockHash h' }

-- -------------------------------------------------------------------------- --
-- Test Chain Database Configurations

peterson :: ChainGraph
peterson = toChainGraph (testChainId . int) G.petersonGraph

singleton :: ChainGraph
singleton = toChainGraph (testChainId . int) G.singleton

testBlockHeaderDbs :: ChainGraph -> ChainwebVersion -> IO [(ChainId, BlockHeaderDb)]
testBlockHeaderDbs g v = mapM (\c -> (c,) <$> db c) $ give g $ toList chainIds
  where
    db c = initBlockHeaderDb . Configuration $ genesisBlockHeader v g c

petersonGenesisBlockHeaderDbs :: IO [(ChainId, BlockHeaderDb)]
petersonGenesisBlockHeaderDbs = testBlockHeaderDbs peterson Test

singletonGenesisBlockHeaderDbs :: IO [(ChainId, BlockHeaderDb)]
singletonGenesisBlockHeaderDbs = testBlockHeaderDbs singleton Test

linearBlockHeaderDbs :: Natural -> IO [(ChainId, BlockHeaderDb)] -> IO [(ChainId, BlockHeaderDb)]
linearBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ (uncurry populateDb) dbs
    return dbs
  where
    populateDb :: ChainId -> BlockHeaderDb -> IO ()
    populateDb cid db = do
        let gbh0 = genesisBlockHeader Test peterson cid
        traverse_ (insert db) . take (int n) $ testBlockHeaders gbh0

starBlockHeaderDbs :: Natural -> IO [(ChainId, BlockHeaderDb)] -> IO [(ChainId, BlockHeaderDb)]
starBlockHeaderDbs n genDbs = do
    dbs <- genDbs
    mapM_ (uncurry populateDb) dbs
    return dbs
  where
    populateDb :: ChainId -> BlockHeaderDb -> IO ()
    populateDb cid db = do
        let gbh0 = genesisBlockHeader Test peterson cid
        traverse_ (\i -> insert db $ newEntry i gbh0) [0 .. (int n-1)]

    newEntry :: Word64 -> BlockHeader -> BlockHeader
    newEntry i h = head $ testBlockHeadersWithNonce (Nonce i) h

-- -------------------------------------------------------------------------- --
-- Toy Server Interaction

-- | Spawn a server that acts as a peer node for the purpose of querying / syncing.
--
withSingleChainServer
    :: [(ChainId, BlockHeaderDb)]
    -> [(NetworkId, P2P.PeerDb)]
    -> (ClientEnv -> IO a)
    -> IO a
withSingleChainServer chainDbs peerDbs f = W.testWithApplication (pure app) work
  where
    app = singleChainApplication Test chainDbs peerDbs
    work port = do
      mgr <- HTTP.newManager HTTP.defaultManagerSettings
      f $ mkClientEnv mgr (BaseUrl Http "localhost" port "")

-- -------------------------------------------------------------------------- --
-- Tasty TestTree Server and Client Environment

testHost :: String
testHost = "localhost"

data TestClientEnv = TestClientEnv
    { _envClientEnv :: !ClientEnv
    , _envBlockHeaderDbs :: ![(ChainId, BlockHeaderDb)]
    , _envPeerDbs :: ![(NetworkId, P2P.PeerDb)]
    }

pattern BlockHeaderDbsTestClientEnv
    :: ClientEnv
    -> [(ChainId, BlockHeaderDb)]
    -> TestClientEnv
pattern BlockHeaderDbsTestClientEnv { _cdbEnvClientEnv, _cdbEnvBlockHeaderDbs }
    = TestClientEnv _cdbEnvClientEnv _cdbEnvBlockHeaderDbs []

pattern PeerDbsTestClientEnv
    :: ClientEnv
    -> [(NetworkId, P2P.PeerDb)]
    -> TestClientEnv
pattern PeerDbsTestClientEnv { _pdbEnvClientEnv, _pdbEnvPeerDbs }
    = TestClientEnv _pdbEnvClientEnv [] _pdbEnvPeerDbs

-- TODO: catch, wrap, and forward exceptions from chainwebApplication
--
withSingleChainTestServer
    :: IO W.Application
    -> (Int -> IO a)
    -> (IO a -> TestTree)
    -> TestTree
withSingleChainTestServer appIO envIO test = withResource start stop $ \x ->
    test $ x >>= \(_, _, env) -> return env
  where
    start = do
        app <- appIO
        (port, sock) <- W.openFreePort
        readyVar <- newEmptyMVar
        server <- async $ do
            let settings = W.setBeforeMainLoop (putMVar readyVar ()) W.defaultSettings
            W.runSettingsSocket settings sock app
        link server
        _ <- takeMVar readyVar
        env <- envIO port
        return (server, sock, env)

    stop (server, sock, _) = do
        uninterruptibleCancel server
        close sock

withSingleChainTestServer_
    :: IO [(ChainId, BlockHeaderDb)]
    -> IO [(NetworkId, P2P.PeerDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withSingleChainTestServer_ chainDbsIO peerDbsIO = withSingleChainTestServer mkApp mkEnv
  where
    mkApp = singleChainApplication Test <$> chainDbsIO <*> peerDbsIO
    mkEnv port = do
        mgr <- HTTP.newManager HTTP.defaultManagerSettings
        TestClientEnv (mkClientEnv mgr (BaseUrl Http testHost port ""))
            <$> chainDbsIO
            <*> peerDbsIO

withPeerDbsServer
    :: IO [(NetworkId, P2P.PeerDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withPeerDbsServer = withSingleChainTestServer_ (return [])

withBlockHeaderDbsServer
    :: IO [(ChainId, BlockHeaderDb)]
    -> (IO TestClientEnv -> TestTree)
    -> TestTree
withBlockHeaderDbsServer chainDbsIO = withSingleChainTestServer_ chainDbsIO (return [])

-- -------------------------------------------------------------------------- --
-- Isomorphisms and Roundtrips

prop_iso :: Eq a => Show a => (b -> a) -> (a -> b) -> a -> Property
prop_iso d e a = a === d (e a)

prop_iso'
    :: Show e
    => Eq a
    => Show a
    => (b -> Either e a)
    -> (a -> b)
    -> a
    -> Property
prop_iso' d e a = Right a === first show (d (e a))

prop_encodeDecodeRoundtrip
    :: Eq a
    => Show a
    => (forall m . MonadGet m => m a)
    -> (forall m . MonadPut m => a -> m ())
    -> a
    -> Property
prop_encodeDecodeRoundtrip d e = prop_iso' (runGetEither d) (runPutS . e)

-- -------------------------------------------------------------------------- --
-- Expectations

assertExpectation
    :: MonadIO m
    => Eq a
    => Show a
    => T.Text
    -> Expected a
    -> Actual a
    -> m ()
assertExpectation msg expected actual = liftIO $ assertBool
    (T.unpack $ unexpectedMsg msg expected actual)
    (getExpected expected == getActual actual)
