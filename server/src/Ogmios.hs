--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-partial-fields #-}

module Ogmios
    ( -- * App
      App (..)
    , application
    , runWith
    , version

    -- * Environment
    , Env (..)
    , newEnvironment

    -- * Command & Options
    , Command (..)
    , Options (..)
    , NetworkParameters (..)
    , parseOptions

    -- * Logging
    , TraceOgmios (..)
    , withStdoutTracer
    ) where

import Ogmios.Prelude

import Cardano.Network.Protocol.NodeToClient
    ( Block )
import Control.Monad.Class.MonadST
    ( MonadST )
import Data.Aeson
    ( ToJSON, genericToEncoding )
import Ogmios.App.Health
    ( Health
    , TraceHealth
    , connectHealthCheckClient
    , emptyHealth
    , newHealthCheckClient
    )
import Ogmios.App.Metrics
    ( RuntimeStats, Sampler, Sensors, TraceMetrics, newSampler, newSensors )
import Ogmios.App.Options
    ( Command (..), NetworkParameters (..), Options (..), parseOptions )
import Ogmios.App.Server
    ( TraceServer, connectHybridServer )
import Ogmios.App.Server.Http
    ( mkHttpApp )
import Ogmios.App.Server.WebSocket
    ( TraceWebSocket, newWebSocketApp )
import Ogmios.Control.Exception
    ( MonadCatch, MonadMask, MonadThrow )
import Ogmios.Control.MonadAsync
    ( MonadAsync (..), MonadFork, MonadThread )
import Ogmios.Control.MonadClock
    ( MonadClock, getCurrentTime, withDebouncer, _10s )
import Ogmios.Control.MonadLog
    ( HasSeverityAnnotation (..)
    , Logger
    , MonadLog (..)
    , Severity (..)
    , withStdoutTracer
    )
import Ogmios.Control.MonadMetrics
    ( MonadMetrics )
import Ogmios.Control.MonadSTM
    ( MonadSTM (..), TVar, newTVar )
import Ogmios.Control.MonadWebSocket
    ( MonadWebSocket )
import Ogmios.Version
    ( version )
import System.Posix.Signals
    ( Handler (..)
    , installHandler
    , keyboardSignal
    , raiseSignal
    , softwareTermination
    )

import qualified Data.Aeson as Json

--
-- App
--

-- | Main application monad.
newtype App a = App
    { unApp :: ReaderT (Env App) IO a
    } deriving newtype
        ( Functor, Applicative, Monad
        , MonadReader (Env App)
        , MonadIO
        , MonadLog, MonadMetrics
        , MonadWebSocket
        , MonadClock
        , MonadSTM, MonadST
        , MonadAsync, MonadThread, MonadFork
        , MonadThrow, MonadCatch, MonadMask
        )

-- | Application runner with an instantiated environment. See 'newEnvironment'.
runWith :: forall a. App a -> Env App -> IO a
runWith app = runReaderT (unApp app)

-- | Ogmios, where everything gets stitched together.
application :: Logger TraceOgmios -> App ()
application tr = hijackSigTerm >> withDebouncer _10s (\debouncer -> do
    env@Env{network} <- ask
    logWith tr (OgmiosNetwork network)

    healthCheckClient <- newHealthCheckClient (contramap OgmiosHealth tr) debouncer

    webSocketApp <- newWebSocketApp (contramap OgmiosWebSocket tr) (`runWith` env)
    httpApp      <- mkHttpApp @_ @_ @Block (`runWith` env)

    concurrently_
        (connectHealthCheckClient
            (contramap OgmiosHealth tr) (`runWith` env) healthCheckClient)
        (connectHybridServer
            (contramap OgmiosServer tr) webSocketApp httpApp)
    )

-- | The runtime does not let the application terminate gracefully when a
-- SIGTERM is received. It does however for SIGINT which allows the application
-- to cleanup sub-processes.
--
-- This function install handlers for SIGTERM and turn them into SIGINT.
hijackSigTerm :: App ()
hijackSigTerm =
    liftIO $ void (installHandler softwareTermination handler empty)
  where
    handler = CatchOnce (raiseSignal keyboardSignal)

--
-- Environment
--

-- | Environment of the application, carrying around what's needed for the
-- application to run.
data Env (m :: Type -> Type) = Env
    { health  :: !(TVar m (Health Block))
    , sensors :: !(Sensors m)
    , sampler :: !(Sampler RuntimeStats m)
    , network :: !NetworkParameters
    , options :: !Options
    } deriving stock (Generic)

newEnvironment
    :: Logger TraceOgmios
    -> NetworkParameters
    -> Options
    -> IO (Env App)
newEnvironment tr network options = do
    health  <- getCurrentTime >>= atomically . newTVar . emptyHealth
    sensors <- newSensors
    sampler <- newSampler (contramap OgmiosMetrics tr)
    pure $ Env{health,sensors,sampler,network,options}

--
-- Logging
--

data TraceOgmios where
    OgmiosHealth
        :: { healthCheck :: TraceHealth (Health Block) }
        -> TraceOgmios

    OgmiosMetrics
        :: { metrics :: TraceMetrics }
        -> TraceOgmios

    OgmiosWebSocket
        :: { webSocket :: TraceWebSocket }
        -> TraceOgmios

    OgmiosServer
        :: { server :: TraceServer }
        -> TraceOgmios

    OgmiosNetwork
        :: { networkParameters :: NetworkParameters }
        -> TraceOgmios
    deriving stock (Generic, Show)

instance ToJSON TraceOgmios where
    toEncoding = genericToEncoding Json.defaultOptions

instance HasSeverityAnnotation TraceOgmios where
    getSeverityAnnotation = \case
        OgmiosHealth msg    -> getSeverityAnnotation msg
        OgmiosMetrics msg   -> getSeverityAnnotation msg
        OgmiosWebSocket msg -> getSeverityAnnotation msg
        OgmiosServer msg    -> getSeverityAnnotation msg
        OgmiosNetwork{}     -> Info
