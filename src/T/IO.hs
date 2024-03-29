{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module T.IO where

import Control.Algebra
import Control.Carrier.Random.Gen
import Control.Carrier.Reader
import Control.Carrier.State.Strict
import Control.Concurrent
import Control.Effect.Labelled (HasLabelled, Labelled, runLabelled, sendLabelled)
import Control.Monad
import Control.Monad.IO.Class
import Control.Tracer
import Data.IORef
import Data.Kind
import GHC.TypeLits
import Sum1
import System.Random (mkStdGen)
import T.HasServer
import TS1

------------------------------------------------------------------
newtype ClientCallC r m a = ClientCallC
  { unClientCallC ::
      ReaderC
        ( Chan (Sum (TReq r), MVar (Sum (TResp r))),
          MVar (Sum (TResp r))
        )
        m
        a
  }
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  ( Algebra sig m,
    MonadIO m
  ) =>
  Algebra (ClientCall r :+: sig) (ClientCallC r m)
  where
  alg hdl sig ctx = ClientCallC $
    ReaderC $ \(chan, mvar) -> case sig of
      L (ClientCall (_ :: Call req resp -> t) req) -> do
        res <- liftIO $ do
          writeChan chan (inject (Req @t req), mvar)
          project @(Resp t resp) <$> takeMVar mvar
        case res of
          Nothing -> error "DO NOT HAPPEN"
          Just (Resp r) -> pure (r <$ ctx)
      R signa -> alg (runReader (chan, mvar) . unClientCallC . hdl) signa ctx

runSupportCall ::
  forall (name :: Symbol) r m a.
  (MonadIO m) =>
  Chan (Sum (TReq r), MVar (Sum (TResp r))) ->
  Labelled name (ClientCallC r) m a ->
  m a
runSupportCall chan f = do
  mvar <- liftIO newEmptyMVar
  runReader (chan, mvar) . unClientCallC @r $ runLabelled f

------------------------------------------------------------------

newtype ServerCallC r m a = ServerCallC
  { unServerCallC ::
      ReaderC
        ( Chan (Sum (TReq r), MVar (Sum (TResp r))),
          IORef (MVar (Sum (TResp r)))
        )
        m
        a
  }
  deriving (Functor, Applicative, Monad, MonadIO)

instance
  ( Algebra sig m,
    MonadIO m
  ) =>
  Algebra (ServerCall r :+: sig) (ServerCallC r m)
  where
  alg hdl sig ctx = ServerCallC $
    ReaderC $ \(chan, ref) -> case sig of
      L ServerGet -> do
        (sv, mvar) <- liftIO $ readChan chan
        liftIO $ writeIORef ref mvar
        pure (sv <$ ctx)
      L (ServerPut s) -> do
        liftIO $ do
          mvar <- readIORef ref
          putMVar mvar s
        pure ctx
      R signa -> alg (runReader (chan, ref) . unServerCallC . hdl) signa ctx

runSupportHandleCall ::
  forall (name :: Symbol) r m a.
  (MonadIO m) =>
  Chan (Sum (TReq r), MVar (Sum (TResp r))) ->
  Labelled name (ServerCallC r) m a ->
  m a
runSupportHandleCall chan f = do
  ref <- liftIO $ newIORef undefined
  runReader (chan, ref) . unServerCallC @r $ runLabelled f

------------------------------------------------------------------
data A where
  A :: Call Int Bool -> A

data B where
  B :: Call Bool String -> B

data C where
  C :: Call Int Int -> C

data D a where
  D :: Call a Int -> D a

data E where
  E :: Call Int Bool -> E

data F where
  F :: Call () Int -> F

type Api a = [K 'A, K 'B, K 'C, K ('D @a), K 'E]

------------------------------------------------------------------
data RespTrace
  = DResp Int
  | AResp Bool
  | BResp String
  deriving (Show)

client ::
  forall a sig m.
  ( SupportCall "a1" (Api a) sig m,
    Has (Reader a) sig m
  ) =>
  Tracer m RespTrace ->
  m ()
client tracer = replicateM_ 10 $ do
  val <- ask @a
  g <- call @"a1" D val
  traceWith tracer $ DResp g

  g <- call @"a1" A 1
  traceWith tracer $ AResp g

  g <- call @"a1" B True
  traceWith tracer $ BResp g

------------------------------------------------------------------
server ::
  forall a sig m.
  ( SupportHandleCall "a1" (Api a) sig m,
    Show a
  ) =>
  Tracer m (ServerTracer (Api a)) ->
  m ()
server serverTracer = forever $ do
  serverHandleCall @"a1" serverTracer $
    (\(Req i) -> do pure (Resp True))
      :| (\(Req i) -> pure (Resp "nice"))
      :| (\(Req i) -> pure (Resp i))
      :| (\(Req i) -> pure (Resp 1))
      :| (\(Req i) -> pure (Resp True))
      :| HNil

------------------------------------------

r :: IO ()
r = do
  chan <- newChan
  forkIO $ void $ runSupportHandleCall @"a1" chan (server @Int (contramap show stdoutTracer))
  void $ runSupportCall @"a1" chan $ runReader @Int 1 (client @Int (contramap show stdoutTracer))
