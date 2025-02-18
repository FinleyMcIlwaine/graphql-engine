{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

-- | Defines the CE version of the engine.
--
-- This module contains everything that is required to run the community edition
-- of the engine: the base application monad and the implementation of all its
-- behaviour classes.
module Hasura.App
  ( ExitCode (AuthConfigurationError, DatabaseMigrationError, DowngradeProcessError, MetadataCleanError, MetadataExportError, SchemaCacheInitError),
    ExitException (ExitException),
    GlobalCtx (..),
    AppContext (..),
    PGMetadataStorageAppT (runPGMetadataStorageAppT),
    accessDeniedErrMsg,
    flushLogger,
    getCatalogStateTx,
    initGlobalCtx,
    initAuthMode,
    initialiseAppContext,
    initialiseContext,
    initSubscriptionsState,
    initLockedEventsCtx,
    initSQLGenCtx,
    mkResponseInternalErrorsConfig,
    migrateCatalogSchema,
    mkLoggers,
    mkPGLogger,
    notifySchemaCacheSyncTx,
    parseArgs,
    throwErrExit,
    throwErrJExit,
    printJSON,
    printYaml,
    readTlsAllowlist,
    resolvePostgresConnInfo,
    runHGEServer,
    setCatalogStateTx,

    -- * Exported for testing
    mkHGEServer,
    mkPgSourceResolver,
    mkMSSQLSourceResolver,
  )
where

import Control.Concurrent.Async.Lifted.Safe qualified as LA
import Control.Concurrent.Extended qualified as C
import Control.Concurrent.STM qualified as STM
import Control.Concurrent.STM.TVar (readTVarIO)
import Control.Exception (bracket_, throwIO)
import Control.Monad.Catch
  ( Exception,
    MonadCatch,
    MonadMask,
    MonadThrow,
    onException,
  )
import Control.Monad.Morph (hoist)
import Control.Monad.STM (atomically)
import Control.Monad.Stateless
import Control.Monad.Trans.Control (MonadBaseControl (..))
import Control.Monad.Trans.Managed (ManagedT (..), allocate, allocate_)
import Control.Retry qualified as Retry
import Data.Aeson qualified as A
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Environment qualified as Env
import Data.FileEmbed (makeRelativeToProject)
import Data.HashMap.Strict qualified as HM
import Data.Set.NonEmpty qualified as NE
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Time.Clock qualified as Clock
import Data.Yaml qualified as Y
import Database.MSSQL.Pool qualified as MSPool
import Database.PG.Query qualified as PG
import Database.PG.Query qualified as Q
import GHC.AssertNF.CPP
import Hasura.App.State
import Hasura.Backends.MSSQL.Connection
import Hasura.Backends.Postgres.Connection
import Hasura.Base.Error
import Hasura.Eventing.Common
import Hasura.Eventing.EventTrigger
import Hasura.Eventing.ScheduledTrigger
import Hasura.GraphQL.Execute
  ( ExecutionStep (..),
    MonadGQLExecutionCheck (..),
    checkQueryInAllowlist,
  )
import Hasura.GraphQL.Execute.Action
import Hasura.GraphQL.Execute.Action.Subscription
import Hasura.GraphQL.Execute.Backend qualified as EB
import Hasura.GraphQL.Execute.Subscription.Poll qualified as ES
import Hasura.GraphQL.Execute.Subscription.State qualified as ES
import Hasura.GraphQL.Logging (MonadQueryLog (..))
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.GraphQL.Transport.HTTP
  ( CacheStoreSuccess (CacheStoreSkipped),
    MonadExecuteQuery (..),
  )
import Hasura.GraphQL.Transport.HTTP.Protocol (toParsed)
import Hasura.GraphQL.Transport.WebSocket.Server qualified as WS
import Hasura.Logging
import Hasura.Metadata.Class
import Hasura.PingSources
import Hasura.Prelude
import Hasura.QueryTags
import Hasura.RQL.DDL.EventTrigger (MonadEventLogCleanup (..))
import Hasura.RQL.DDL.Schema.Cache
import Hasura.RQL.DDL.Schema.Cache.Common
import Hasura.RQL.DDL.Schema.Catalog
import Hasura.RQL.Types.Allowlist
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Eventing.Backend
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Network
import Hasura.RQL.Types.ResizePool
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.SchemaCache.Build
import Hasura.RQL.Types.Source
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.SQL.Backend
import Hasura.Server.API.Query (requiresAdmin)
import Hasura.Server.App
import Hasura.Server.Auth
import Hasura.Server.CheckUpdates (checkForUpdates)
import Hasura.Server.Init
import Hasura.Server.Limits
import Hasura.Server.Logging
import Hasura.Server.Metrics (ServerMetrics (..))
import Hasura.Server.Migrate (migrateCatalog)
import Hasura.Server.Prometheus
  ( PrometheusMetrics (..),
    decWarpThreads,
    incWarpThreads,
  )
import Hasura.Server.SchemaCacheRef
  ( SchemaCacheRef,
    getSchemaCache,
    initialiseSchemaCacheRef,
    logInconsistentMetadata,
  )
import Hasura.Server.SchemaUpdate
import Hasura.Server.Telemetry
import Hasura.Server.Types
import Hasura.Server.Version
import Hasura.Services
import Hasura.Session
import Hasura.ShutdownLatch
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Blocklisting (Blocklist)
import Network.HTTP.Client.CreateManager (mkHttpManager)
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Options.Applicative
import Refined (unrefine)
import System.Log.FastLogger qualified as FL
import System.Metrics qualified as EKG
import System.Metrics.Gauge qualified as EKG.Gauge
import Text.Mustache.Compile qualified as M
import Web.Spock.Core qualified as Spock

data ExitCode
  = -- these are used during server initialization:
    InvalidEnvironmentVariableOptionsError
  | InvalidDatabaseConnectionParamsError
  | AuthConfigurationError
  | EventSubSystemError
  | DatabaseMigrationError
  | -- | used by MT because it initialises the schema cache only
    -- these are used in app/Main.hs:
    SchemaCacheInitError
  | MetadataExportError
  | MetadataCleanError
  | ExecuteProcessError
  | DowngradeProcessError
  deriving (Show)

data ExitException = ExitException
  { eeCode :: !ExitCode,
    eeMessage :: !BC.ByteString
  }
  deriving (Show)

instance Exception ExitException

throwErrExit :: (MonadIO m) => forall a. ExitCode -> String -> m a
throwErrExit reason = liftIO . throwIO . ExitException reason . BC.pack

throwErrJExit :: (A.ToJSON a, MonadIO m) => forall b. ExitCode -> a -> m b
throwErrJExit reason = liftIO . throwIO . ExitException reason . BLC.toStrict . A.encode

--------------------------------------------------------------------------------
-- TODO(SOLOMON): Move Into `Hasura.Server.Init`. Unable to do so
-- currently due `throwErrExit`.

-- | Parse cli arguments to graphql-engine executable.
parseArgs :: EnabledLogTypes impl => Env.Environment -> IO (HGEOptions (ServeOptions impl))
parseArgs env = do
  rawHGEOpts <- execParser opts
  let eitherOpts = runWithEnv (Env.toList env) $ mkHGEOptions rawHGEOpts
  onLeft eitherOpts $ throwErrExit InvalidEnvironmentVariableOptionsError
  where
    opts =
      info
        (helper <*> parseHgeOpts)
        ( fullDesc
            <> header "Hasura GraphQL Engine: Blazing fast, instant realtime GraphQL APIs on your DB with fine grained access control, also trigger webhooks on database events."
            <> footerDoc (Just mainCmdFooter)
        )

--------------------------------------------------------------------------------

printJSON :: (A.ToJSON a, MonadIO m) => a -> m ()
printJSON = liftIO . BLC.putStrLn . A.encode

printYaml :: (A.ToJSON a, MonadIO m) => a -> m ()
printYaml = liftIO . BC.putStrLn . Y.encode

mkPGLogger :: Logger Hasura -> PG.PGLogger
mkPGLogger (Logger logger) (PG.PLERetryMsg msg) =
  logger $ PGLog LevelWarn msg

-- | Context required for all graphql-engine CLI commands
data GlobalCtx = GlobalCtx
  { _gcMetadataDbConnInfo :: !PG.ConnInfo,
    -- | --database-url option, @'UrlConf' is required to construct default source configuration
    -- and optional retries
    _gcDefaultPostgresConnInfo :: !(Maybe (UrlConf, PG.ConnInfo), Maybe Int)
  }

readTlsAllowlist :: SchemaCacheRef -> IO [TlsAllow]
readTlsAllowlist scRef = scTlsAllowlist <$> getSchemaCache scRef

initGlobalCtx ::
  (MonadIO m) =>
  Env.Environment ->
  -- | the metadata DB URL
  Maybe String ->
  -- | the user's DB URL
  PostgresConnInfo (Maybe UrlConf) ->
  m GlobalCtx
initGlobalCtx env metadataDbUrl defaultPgConnInfo = do
  let PostgresConnInfo dbUrlConf maybeRetries = defaultPgConnInfo
      mkConnInfoFromSource dbUrl = do
        resolvePostgresConnInfo env dbUrl maybeRetries

      mkConnInfoFromMDb mdbUrl =
        let retries = fromMaybe 1 maybeRetries
         in (PG.ConnInfo retries . PG.CDDatabaseURI . txtToBs . T.pack) mdbUrl

      mkGlobalCtx mdbConnInfo sourceConnInfo =
        pure $ GlobalCtx mdbConnInfo (sourceConnInfo, maybeRetries)

  case (metadataDbUrl, dbUrlConf) of
    (Nothing, Nothing) ->
      throwErrExit
        InvalidDatabaseConnectionParamsError
        "Fatal Error: Either of --metadata-database-url or --database-url option expected"
    -- If no metadata storage specified consider use default database as
    -- metadata storage
    (Nothing, Just dbUrl) -> do
      connInfo <- mkConnInfoFromSource dbUrl
      mkGlobalCtx connInfo $ Just (dbUrl, connInfo)
    (Just mdUrl, Nothing) -> do
      let mdConnInfo = mkConnInfoFromMDb mdUrl
      mkGlobalCtx mdConnInfo Nothing
    (Just mdUrl, Just dbUrl) -> do
      srcConnInfo <- mkConnInfoFromSource dbUrl
      let mdConnInfo = mkConnInfoFromMDb mdUrl
      mkGlobalCtx mdConnInfo (Just (dbUrl, srcConnInfo))

-- | An application with Postgres database as a metadata storage
newtype PGMetadataStorageAppT m a = PGMetadataStorageAppT {runPGMetadataStorageAppT :: (AppContext, AppEnv) -> m a}
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadFix,
      MonadCatch,
      MonadThrow,
      MonadMask,
      HasServerConfigCtx,
      MonadReader (AppContext, AppEnv),
      MonadBase b,
      MonadBaseControl b
    )
    via (ReaderT (AppContext, AppEnv) m)
  deriving
    ( MonadTrans
    )
    via (ReaderT (AppContext, AppEnv))

instance Monad m => ProvidesNetwork (PGMetadataStorageAppT m) where
  askHTTPManager = appEnvManager <$> asks snd

resolvePostgresConnInfo ::
  (MonadIO m) => Env.Environment -> UrlConf -> Maybe Int -> m PG.ConnInfo
resolvePostgresConnInfo env dbUrlConf maybeRetries = do
  dbUrlText <-
    runExcept (resolveUrlConf env dbUrlConf) `onLeft` \err ->
      liftIO (throwErrJExit InvalidDatabaseConnectionParamsError err)
  pure $ PG.ConnInfo retries $ PG.CDDatabaseURI $ txtToBs dbUrlText
  where
    retries = fromMaybe 1 maybeRetries

initAuthMode ::
  (C.ForkableMonadIO m, Tracing.HasReporter m) =>
  HashSet AdminSecretHash ->
  Maybe AuthHook ->
  [JWTConfig] ->
  Maybe RoleName ->
  HTTP.Manager ->
  Logger Hasura ->
  m AuthMode
initAuthMode adminSecret authHook jwtSecret unAuthRole httpManager logger = do
  authModeRes <-
    runExceptT $
      setupAuthMode
        adminSecret
        authHook
        jwtSecret
        unAuthRole
        logger
        httpManager

  authMode <- onLeft authModeRes (throwErrExit AuthConfigurationError . T.unpack)
  -- forking a dedicated polling thread to dynamically get the latest JWK settings
  -- set by the user and update the JWK accordingly. This will help in applying the
  -- updates without restarting HGE.
  _ <- C.forkImmortal "update JWK" logger $ updateJwkCtx authMode httpManager logger
  return authMode

initSubscriptionsState ::
  Logger Hasura ->
  Maybe ES.SubscriptionPostPollHook ->
  IO ES.SubscriptionsState
initSubscriptionsState logger liveQueryHook = ES.initSubscriptionsState postPollHook
  where
    postPollHook = fromMaybe (ES.defaultSubscriptionPostPollHook logger) liveQueryHook

initLockedEventsCtx :: IO LockedEventsCtx
initLockedEventsCtx = LockedEventsCtx <$> STM.newTVarIO mempty <*> STM.newTVarIO mempty <*> STM.newTVarIO mempty <*> STM.newTVarIO mempty

mkResponseInternalErrorsConfig :: AdminInternalErrorsStatus -> DevModeStatus -> ResponseInternalErrorsConfig
mkResponseInternalErrorsConfig adminInternalErrors devMode = do
  if
      | isDevModeEnabled devMode -> InternalErrorsAllRequests
      | isAdminInternalErrorsEnabled adminInternalErrors -> InternalErrorsAdminOnly
      | otherwise -> InternalErrorsDisabled

initSQLGenCtx :: Options.StringifyNumbers -> Options.DangerouslyCollapseBooleans -> HashSet ExperimentalFeature -> SQLGenCtx
initSQLGenCtx strinfigyNum dangerousBooleanCollapse experimentalFeatures =
  SQLGenCtx
    strinfigyNum
    dangerousBooleanCollapse
    optimizePermissionFilters
    bigqueryStringNumericInput
  where
    optimizePermissionFilters
      | EFOptimizePermissionFilters `elem` experimentalFeatures = Options.OptimizePermissionFilters
      | otherwise = Options.Don'tOptimizePermissionFilters

    bigqueryStringNumericInput
      | EFBigQueryStringNumericInput `elem` experimentalFeatures = Options.EnableBigQueryStringNumericInput
      | otherwise = Options.DisableBigQueryStringNumericInput

initialiseAppContext :: (MonadIO m) => HTTP.Manager -> ServeOptions impl -> Env.Environment -> SchemaCacheRef -> Logger Hasura -> SQLGenCtx -> m AppContext
initialiseAppContext httpManager ServeOptions {..} env schemaCacheRef logger sqlGenCtx = do
  authMode <- liftIO $ initAuthMode soAdminSecret soAuthHook soJwtSecret soUnAuthRole httpManager logger

  let appCtx =
        AppContext
          { acCacheRef = schemaCacheRef,
            acAuthMode = authMode,
            acSQLGenCtx = sqlGenCtx,
            acEnabledAPIs = soEnabledAPIs,
            acEnableAllowlist = soEnableAllowList,
            acResponseInternalErrorsConfig = mkResponseInternalErrorsConfig soAdminInternalErrors soDevMode,
            acEnvironment = env,
            acRemoteSchemaPermsCtx = soEnableRemoteSchemaPermissions,
            acFunctionPermsCtx = soInferFunctionPermissions,
            acExperimentalFeatures = soExperimentalFeatures,
            acDefaultNamingConvention = soDefaultNamingConvention,
            acMetadataDefaults = soMetadataDefaults,
            acLiveQueryOptions = soLiveQueryOpts,
            acStreamQueryOptions = soStreamingQueryOpts,
            acCorsConfig = soCorsConfig,
            acConsoleStatus = soConsoleStatus,
            acEnableTelemetry = soEnableTelemetry,
            acEventsHttpPoolSize = soEventsHttpPoolSize,
            acEventsFetchInterval = soEventsFetchInterval,
            acAsyncActionsFetchInterval = soAsyncActionsFetchInterval,
            acSchemaPollInterval = soSchemaPollInterval,
            acEventsFetchBatchSize = soEventsFetchBatchSize
          }
  return appCtx

-- | Initializes or migrates the catalog and returns the context required to start the server.
initialiseContext ::
  (C.ForkableMonadIO m, MonadCatch m) =>
  Env.Environment ->
  GlobalCtx ->
  ServeOptions Hasura ->
  Maybe ES.SubscriptionPostPollHook ->
  ServerMetrics ->
  PrometheusMetrics ->
  Tracing.SamplingPolicy ->
  ManagedT m (AppContext, AppEnv)
initialiseContext env GlobalCtx {..} serveOptions@ServeOptions {..} liveQueryHook serverMetrics prometheusMetrics traceSamplingPolicy = do
  instanceId <- liftIO generateInstanceId
  latch <- liftIO newShutdownLatch
  loggers@(Loggers loggerCtx logger pgLogger) <- mkLoggers soEnabledLogTypes soLogLevel
  when (null soAdminSecret) $ do
    let errMsg :: Text
        errMsg = "WARNING: No admin secret provided"
    unLogger logger $
      StartupLog
        { slLogLevel = LevelWarn,
          slKind = "no_admin_secret",
          slInfo = A.toJSON errMsg
        }
  -- log serve options
  unLogger logger $ serveOptsToLog serveOptions

  -- log postgres connection info
  unLogger logger $ connInfoToLog _gcMetadataDbConnInfo

  metadataDbPool <-
    allocate
      (liftIO $ PG.initPGPool _gcMetadataDbConnInfo soConnParams pgLogger)
      (liftIO . PG.destroyPGPool)

  let maybeDefaultSourceConfig =
        fst _gcDefaultPostgresConnInfo <&> \(dbUrlConf, _) ->
          let connSettings =
                PostgresPoolSettings
                  { _ppsMaxConnections = Just $ Q.cpConns soConnParams,
                    _ppsTotalMaxConnections = Nothing,
                    _ppsIdleTimeout = Just $ Q.cpIdleTime soConnParams,
                    _ppsRetries = snd _gcDefaultPostgresConnInfo <|> Just 1,
                    _ppsPoolTimeout = PG.cpTimeout soConnParams,
                    _ppsConnectionLifetime = PG.cpMbLifetime soConnParams
                  }
              sourceConnInfo = PostgresSourceConnInfo dbUrlConf (Just connSettings) (PG.cpAllowPrepare soConnParams) soTxIso Nothing
           in PostgresConnConfiguration sourceConnInfo Nothing defaultPostgresExtensionsSchema Nothing mempty
      sqlGenCtx = initSQLGenCtx soStringifyNum soDangerousBooleanCollapse soExperimentalFeatures
      checkFeatureFlag' = checkFeatureFlag env
      serverConfigCtx =
        ServerConfigCtx
          soInferFunctionPermissions
          soEnableRemoteSchemaPermissions
          sqlGenCtx
          soEnableMaintenanceMode
          soExperimentalFeatures
          soEventingMode
          soReadOnlyMode
          soDefaultNamingConvention
          soMetadataDefaults
          checkFeatureFlag'

  rebuildableSchemaCache <-
    lift . flip onException (flushLogger loggerCtx) $
      migrateCatalogSchema
        env
        logger
        metadataDbPool
        maybeDefaultSourceConfig
        mempty
        serverConfigCtx
        (mkPgSourceResolver pgLogger)
        mkMSSQLSourceResolver
        soExtensionsSchema

  -- Start a background thread for listening schema sync events from other server instances,
  metaVersionRef <- liftIO $ STM.newEmptyTMVarIO

  -- An interval of 0 indicates that no schema sync is required
  case soSchemaPollInterval of
    Skip -> unLogger logger $ mkGenericLog @Text LevelInfo "schema-sync" "Schema sync disabled"
    Interval interval -> do
      unLogger logger $ mkGenericLog @String LevelInfo "schema-sync" ("Schema sync enabled. Polling at " <> show interval)
      void $ startSchemaSyncListenerThread logger metadataDbPool instanceId interval metaVersionRef

  schemaCacheRef <- initialiseSchemaCacheRef serverMetrics rebuildableSchemaCache

  srvMgr <- liftIO $ mkHttpManager (readTlsAllowlist schemaCacheRef) mempty

  subscriptionsState <- liftIO $ initSubscriptionsState logger liveQueryHook

  lockedEventsCtx <- liftIO $ initLockedEventsCtx

  appCtx <- liftIO $ initialiseAppContext srvMgr serveOptions env schemaCacheRef logger sqlGenCtx

  let appEnv =
        AppEnv
          { appEnvPort = soPort,
            appEnvHost = soHost,
            appEnvMetadataDbPool = metadataDbPool,
            appEnvManager = srvMgr,
            appEnvLoggers = loggers,
            appEnvMetadataVersionRef = metaVersionRef,
            appEnvInstanceId = instanceId,
            appEnvEnableMaintenanceMode = soEnableMaintenanceMode,
            appEnvLoggingSettings = LoggingSettings soEnabledLogTypes soEnableMetadataQueryLogging,
            appEnvEventingMode = soEventingMode,
            appEnvEnableReadOnlyMode = soReadOnlyMode,
            appEnvServerMetrics = serverMetrics,
            appEnvShutdownLatch = latch,
            appEnvMetaVersionRef = metaVersionRef,
            appEnvPrometheusMetrics = prometheusMetrics,
            appEnvTraceSamplingPolicy = traceSamplingPolicy,
            appEnvSubscriptionState = subscriptionsState,
            appEnvLockedEventsCtx = lockedEventsCtx,
            appEnvConnParams = soConnParams,
            appEnvTxIso = soTxIso,
            appEnvConsoleAssetsDir = soConsoleAssetsDir,
            appEnvConsoleSentryDsn = soConsoleSentryDsn,
            appEnvConnectionOptions = soConnectionOptions,
            appEnvWebSocketKeepAlive = soWebSocketKeepAlive,
            appEnvWebSocketConnectionInitTimeout = soWebSocketConnectionInitTimeout,
            appEnvGracefulShutdownTimeout = soGracefulShutdownTimeout,
            appEnvCheckFeatureFlag = checkFeatureFlag'
          }
  pure (appCtx, appEnv)

mkLoggers ::
  (MonadIO m, MonadBaseControl IO m) =>
  HashSet (EngineLogType Hasura) ->
  LogLevel ->
  ManagedT m Loggers
mkLoggers enabledLogs logLevel = do
  loggerCtx <- mkLoggerCtx (defaultLoggerSettings True logLevel) enabledLogs
  let logger = mkLogger loggerCtx
      pgLogger = mkPGLogger logger
  return $ Loggers loggerCtx logger pgLogger

-- | helper function to initialize or migrate the @hdb_catalog@ schema (used by pro as well)
migrateCatalogSchema ::
  (MonadIO m, MonadBaseControl IO m) =>
  Env.Environment ->
  Logger Hasura ->
  PG.PGPool ->
  Maybe (SourceConnConfiguration ('Postgres 'Vanilla)) ->
  Blocklist ->
  ServerConfigCtx ->
  SourceResolver ('Postgres 'Vanilla) ->
  SourceResolver ('MSSQL) ->
  ExtensionsSchema ->
  m RebuildableSchemaCache
migrateCatalogSchema
  env
  logger
  pool
  defaultSourceConfig
  blockList
  serverConfigCtx
  pgSourceResolver
  mssqlSourceResolver
  extensionsSchema = do
    initialiseResult <- runExceptT $ do
      -- TODO: should we allow the migration to happen during maintenance mode?
      -- Allowing this can be a sanity check, to see if the hdb_catalog in the
      -- DB has been set correctly
      currentTime <- liftIO Clock.getCurrentTime
      (migrationResult, metadata) <-
        PG.runTx pool (PG.Serializable, Just PG.ReadWrite) $
          migrateCatalog
            defaultSourceConfig
            extensionsSchema
            (_sccMaintenanceMode serverConfigCtx)
            currentTime
      let tlsAllowList = networkTlsAllowlist $ _metaNetwork metadata
      httpManager <- liftIO $ mkHttpManager (pure tlsAllowList) blockList
      let cacheBuildParams =
            CacheBuildParams httpManager pgSourceResolver mssqlSourceResolver serverConfigCtx
          buildReason = CatalogSync
      schemaCache <-
        runCacheBuild cacheBuildParams $
          buildRebuildableSchemaCacheWithReason buildReason logger env metadata
      pure (migrationResult, schemaCache)

    (migrationResult, schemaCache) <-
      initialiseResult `onLeft` \err -> do
        unLogger
          logger
          StartupLog
            { slLogLevel = LevelError,
              slKind = "catalog_migrate",
              slInfo = A.toJSON err
            }
        liftIO (throwErrJExit DatabaseMigrationError err)
    unLogger logger migrationResult
    pure schemaCache

-- | Event triggers live in the user's DB and other events
--  (cron, one-off and async actions)
--   live in the metadata DB, so we need a way to differentiate the
--   type of shutdown action
data ShutdownAction
  = EventTriggerShutdownAction (IO ())
  | MetadataDBShutdownAction (ExceptT QErr IO ())

-- | If an exception is encountered , flush the log buffer and
-- rethrow If we do not flush the log buffer on exception, then log lines
-- may be missed
-- See: https://github.com/hasura/graphql-engine/issues/4772
flushLogger :: MonadIO m => LoggerCtx impl -> m ()
flushLogger = liftIO . FL.flushLogStr . _lcLoggerSet

-- | This function acts as the entrypoint for the graphql-engine webserver.
--
-- Note: at the exit of this function, or in case of a graceful server shutdown
-- (SIGTERM, or more generally, whenever the shutdown latch is set),  we need to
-- make absolutely sure that we clean up any resources which were allocated during
-- server setup. In the case of a multitenant process, failure to do so can lead to
-- resource leaks.
--
-- To track these resources, we use the ManagedT monad, and attach finalizers at
-- the same point in the code where we allocate resources. If you fork a new
-- long-lived thread, or create a connection pool, or allocate any other
-- long-lived resource, make sure to pair the allocator  with its finalizer.
-- There are plenty of examples throughout the code. For example, see
-- 'C.forkManagedT'.
--
-- Note also: the order in which the finalizers run can be important. Specifically,
-- we want the finalizers for the logger threads to run last, so that we retain as
-- many "thread stopping" log messages as possible. The order in which the
-- finalizers is run is determined by the order in which they are introduced in the
-- code.

{- HLINT ignore runHGEServer "Avoid lambda" -}
{- HLINT ignore runHGEServer "Use withAsync" -}
runHGEServer ::
  forall m.
  ( MonadIO m,
    MonadFix m,
    MonadMask m,
    MonadStateless IO m,
    LA.Forall (LA.Pure m),
    UserAuthentication (Tracing.TraceT m),
    HttpLog m,
    ConsoleRenderer m,
    MonadVersionAPIWithExtraData m,
    MonadMetadataApiAuthorization m,
    MonadGQLExecutionCheck m,
    MonadConfigApiHandler m,
    MonadQueryLog m,
    WS.MonadWSLog m,
    MonadExecuteQuery m,
    Tracing.HasReporter m,
    HasResourceLimits m,
    MonadMetadataStorageQueryAPI m,
    MonadResolveSource m,
    EB.MonadQueryTags m,
    MonadEventLogCleanup m,
    ProvidesHasuraServices m
  ) =>
  (AppContext -> Spock.SpockT m ()) ->
  AppContext ->
  AppEnv ->
  -- | start time
  UTCTime ->
  -- | A hook which can be called to indicate when the server is started succesfully
  Maybe (IO ()) ->
  EKG.Store EKG.EmptyMetrics ->
  ManagedT m ()
runHGEServer setupHook appCtx appEnv@AppEnv {..} initTime startupStatusHook ekgStore = do
  waiApplication <-
    mkHGEServer setupHook appCtx appEnv ekgStore

  let logger = _lsLogger appEnvLoggers
  -- `startupStatusHook`: add `Service started successfully` message to config_status
  -- table when a tenant starts up in multitenant
  let warpSettings :: Warp.Settings
      warpSettings =
        Warp.setPort (_getPort appEnvPort)
          . Warp.setHost appEnvHost
          . Warp.setGracefulShutdownTimeout (Just 30) -- 30s graceful shutdown
          . Warp.setInstallShutdownHandler shutdownHandler
          . Warp.setBeforeMainLoop (for_ startupStatusHook id)
          . setForkIOWithMetrics
          $ Warp.defaultSettings

      setForkIOWithMetrics :: Warp.Settings -> Warp.Settings
      setForkIOWithMetrics = Warp.setFork \f -> do
        void $
          C.forkIOWithUnmask
            ( \unmask ->
                bracket_
                  ( do
                      EKG.Gauge.inc (smWarpThreads appEnvServerMetrics)
                      incWarpThreads (pmConnections appEnvPrometheusMetrics)
                  )
                  ( do
                      EKG.Gauge.dec (smWarpThreads appEnvServerMetrics)
                      decWarpThreads (pmConnections appEnvPrometheusMetrics)
                  )
                  (f unmask)
            )

      shutdownHandler :: IO () -> IO ()
      shutdownHandler closeSocket =
        LA.link =<< LA.async do
          waitForShutdown appEnvShutdownLatch
          unLogger logger $ mkGenericLog @Text LevelInfo "server" "gracefully shutting down server"
          closeSocket

  finishTime <- liftIO Clock.getCurrentTime
  let apiInitTime = realToFrac $ Clock.diffUTCTime finishTime initTime
  unLogger logger $
    mkGenericLog LevelInfo "server" $
      StartupTimeInfo "starting API server" apiInitTime

  -- Here we block until the shutdown latch 'MVar' is filled, and then
  -- shut down the server. Once this blocking call returns, we'll tidy up
  -- any resources using the finalizers attached using 'ManagedT' above.
  -- Structuring things using the shutdown latch in this way lets us decide
  -- elsewhere exactly how we want to control shutdown.
  liftIO $ Warp.runSettings warpSettings waiApplication

-- | Part of a factorization of 'runHGEServer' to expose the constructed WAI
-- application for testing purposes. See 'runHGEServer' for documentation.
mkHGEServer ::
  forall m.
  ( MonadIO m,
    MonadFix m,
    MonadMask m,
    MonadStateless IO m,
    LA.Forall (LA.Pure m),
    UserAuthentication (Tracing.TraceT m),
    HttpLog m,
    ConsoleRenderer m,
    MonadVersionAPIWithExtraData m,
    MonadMetadataApiAuthorization m,
    MonadGQLExecutionCheck m,
    MonadConfigApiHandler m,
    MonadQueryLog m,
    WS.MonadWSLog m,
    MonadExecuteQuery m,
    Tracing.HasReporter m,
    HasResourceLimits m,
    MonadMetadataStorageQueryAPI m,
    MonadResolveSource m,
    EB.MonadQueryTags m,
    MonadEventLogCleanup m,
    ProvidesHasuraServices m
  ) =>
  (AppContext -> Spock.SpockT m ()) ->
  AppContext ->
  AppEnv ->
  EKG.Store EKG.EmptyMetrics ->
  ManagedT m Application
mkHGEServer setupHook appCtx@AppContext {..} appEnv@AppEnv {..} ekgStore = do
  -- Comment this to enable expensive assertions from "GHC.AssertNF". These
  -- will log lines to STDOUT containing "not in normal form". In the future we
  -- could try to integrate this into our tests. For now this is a development
  -- tool.
  --
  -- NOTE: be sure to compile WITHOUT code coverage, for this to work properly.
  liftIO disableAssertNF
  let Loggers loggerCtx logger _ = appEnvLoggers

  HasuraApp app cacheRef actionSubState stopWsServer <-
    lift $
      flip onException (flushLogger loggerCtx) $
        mkWaiApp
          setupHook
          appCtx
          appEnv
          ekgStore

  -- Init ServerConfigCtx
  let serverConfigCtx =
        ServerConfigCtx
          acFunctionPermsCtx
          acRemoteSchemaPermsCtx
          acSQLGenCtx
          appEnvEnableMaintenanceMode
          acExperimentalFeatures
          appEnvEventingMode
          appEnvEnableReadOnlyMode
          acDefaultNamingConvention
          acMetadataDefaults
          appEnvCheckFeatureFlag

  -- Log Warning if deprecated environment variables are used
  sources <- scSources <$> liftIO (getSchemaCache cacheRef)
  liftIO $ logDeprecatedEnvVars logger acEnvironment sources

  -- log inconsistent schema objects
  inconsObjs <- scInconsistentObjs <$> liftIO (getSchemaCache cacheRef)
  liftIO $ logInconsistentMetadata logger inconsObjs

  -- NOTE: `newLogTVar` is being used to make sure that the metadata logger runs only once
  --       while logging errors or any `inconsistent_metadata` logs.
  newLogTVar <- liftIO $ STM.newTVarIO False

  -- Start a background thread for processing schema sync event present in the '_sscSyncEventRef'
  _ <-
    startSchemaSyncProcessorThread
      logger
      appEnvMetaVersionRef
      cacheRef
      appEnvInstanceId
      serverConfigCtx
      newLogTVar

  case appEnvEventingMode of
    EventingEnabled -> do
      startEventTriggerPollerThread logger appEnvLockedEventsCtx cacheRef
      startAsyncActionsPollerThread logger appEnvLockedEventsCtx cacheRef actionSubState

      -- Create logger for logging the statistics of fetched cron triggers
      fetchedCronTriggerStatsLogger <-
        allocate
          (createFetchedCronTriggerStatsLogger logger)
          (closeFetchedCronTriggersStatsLogger logger)

      -- start a background thread to create new cron events
      _cronEventsThread <-
        C.forkManagedT "runCronEventsGenerator" logger $
          runCronEventsGenerator logger fetchedCronTriggerStatsLogger (getSchemaCache cacheRef)

      startScheduledEventsPollerThread logger appEnvLockedEventsCtx cacheRef
    EventingDisabled ->
      unLogger logger $ mkGenericLog @Text LevelInfo "server" "starting in eventing disabled mode"

  -- start a background thread to check for updates
  _updateThread <-
    C.forkManagedT "checkForUpdates" logger $
      liftIO $
        checkForUpdates loggerCtx appEnvManager

  -- Start a background thread for source pings
  _sourcePingPoller <-
    C.forkManagedT "sourcePingPoller" logger $ do
      let pingLog =
            unLogger logger . mkGenericLog @String LevelInfo "sources-ping"
      liftIO
        ( runPingSources
            acEnvironment
            pingLog
            (scSourcePingConfig <$> getSchemaCache cacheRef)
        )

  -- start a background thread for telemetry
  _telemetryThread <-
    if isTelemetryEnabled acEnableTelemetry
      then do
        lift . unLogger logger $ mkGenericLog @Text LevelInfo "telemetry" telemetryNotice

        dbUid <-
          getMetadataDbUid `onLeftM` throwErrJExit DatabaseMigrationError
        pgVersion <-
          liftIO (runExceptT $ PG.runTx appEnvMetadataDbPool (PG.ReadCommitted, Nothing) $ getPgVersion)
            `onLeftM` throwErrJExit DatabaseMigrationError

        telemetryThread <-
          C.forkManagedT "runTelemetry" logger $
            liftIO $
              runTelemetry logger appEnvManager (getSchemaCache cacheRef) dbUid appEnvInstanceId pgVersion acExperimentalFeatures
        return $ Just telemetryThread
      else return Nothing

  -- These cleanup actions are not directly associated with any
  -- resource, but we still need to make sure we clean them up here.
  allocate_ (pure ()) (liftIO stopWsServer)

  pure app
  where
    isRetryRequired _ resp = do
      return $ case resp of
        Right _ -> False
        Left err -> qeCode err == ConcurrentUpdate

    prepareScheduledEvents (Logger logger) = do
      liftIO $ logger $ mkGenericLog @Text LevelInfo "scheduled_triggers" "preparing data"
      res <- Retry.retrying Retry.retryPolicyDefault isRetryRequired (return unlockAllLockedScheduledEvents)
      onLeft res (\err -> logger $ mkGenericLog @String LevelError "scheduled_triggers" (show $ qeError err))

    getProcessingScheduledEventsCount :: LockedEventsCtx -> IO Int
    getProcessingScheduledEventsCount LockedEventsCtx {..} = do
      processingCronEvents <- readTVarIO leCronEvents
      processingOneOffEvents <- readTVarIO leOneOffEvents
      return $ length processingOneOffEvents + length processingCronEvents

    shutdownEventTriggerEvents ::
      [BackendSourceInfo] ->
      Logger Hasura ->
      LockedEventsCtx ->
      IO ()
    shutdownEventTriggerEvents sources (Logger logger) LockedEventsCtx {..} = do
      -- TODO: is this correct?
      -- event triggers should be tied to the life cycle of a source
      lockedEvents <- readTVarIO leEvents
      forM_ sources $ \backendSourceInfo -> do
        AB.dispatchAnyBackend @BackendEventTrigger backendSourceInfo \(SourceInfo sourceName _ _ _ sourceConfig _ _ :: SourceInfo b) -> do
          let sourceNameText = sourceNameToText sourceName
          logger $ mkGenericLog LevelInfo "event_triggers" $ "unlocking events of source: " <> sourceNameText
          for_ (HM.lookup sourceName lockedEvents) $ \sourceLockedEvents -> do
            -- No need to execute unlockEventsTx when events are not present
            for_ (NE.nonEmptySet sourceLockedEvents) $ \nonEmptyLockedEvents -> do
              res <- Retry.retrying Retry.retryPolicyDefault isRetryRequired (return $ unlockEventsInSource @b sourceConfig nonEmptyLockedEvents)
              case res of
                Left err ->
                  logger $
                    mkGenericLog LevelWarn "event_trigger" $
                      "Error while unlocking event trigger events of source: " <> sourceNameText <> " error:" <> showQErr err
                Right count ->
                  logger $
                    mkGenericLog LevelInfo "event_trigger" $
                      tshow count <> " events of source " <> sourceNameText <> " were successfully unlocked"

    shutdownAsyncActions ::
      LockedEventsCtx ->
      ExceptT QErr m ()
    shutdownAsyncActions lockedEventsCtx = do
      lockedActionEvents <- liftIO $ readTVarIO $ leActionEvents lockedEventsCtx
      liftEitherM $ setProcessingActionLogsToPending (LockedActionIdArray $ toList lockedActionEvents)

    -- This function is a helper function to do couple of things:
    --
    -- 1. When the value of the `graceful-shutdown-timeout` > 0, we poll
    --    the in-flight events queue we maintain using the `processingEventsCountAction`
    --    number of in-flight processing events, in case of actions it is the
    --    actions which are in 'processing' state and in scheduled events
    --    it is the events which are in 'locked' state. The in-flight events queue is polled
    --    every 5 seconds until either the graceful shutdown time is exhausted
    --    or the number of in-flight processing events is 0.
    -- 2. After step 1, we unlock all the events which were attempted to process by the current
    --    graphql-engine instance that are still in the processing
    --    state. In actions, it means to set the status of such actions to 'pending'
    --    and in scheduled events, the status will be set to 'unlocked'.
    waitForProcessingAction ::
      Logger Hasura ->
      String ->
      IO Int ->
      ShutdownAction ->
      Seconds ->
      IO ()
    waitForProcessingAction l@(Logger logger) actionType processingEventsCountAction' shutdownAction maxTimeout
      | maxTimeout <= 0 = do
          case shutdownAction of
            EventTriggerShutdownAction userDBShutdownAction -> userDBShutdownAction
            MetadataDBShutdownAction metadataDBShutdownAction ->
              runExceptT metadataDBShutdownAction >>= \case
                Left err ->
                  logger $
                    mkGenericLog LevelWarn (T.pack actionType) $
                      "Error while unlocking the processing  "
                        <> tshow actionType
                        <> " err - "
                        <> showQErr err
                Right () -> pure ()
      | otherwise = do
          processingEventsCount <- processingEventsCountAction'
          if (processingEventsCount == 0)
            then
              logger $
                mkGenericLog @Text LevelInfo (T.pack actionType) $
                  "All in-flight events have finished processing"
            else unless (processingEventsCount == 0) $ do
              C.sleep (5) -- sleep for 5 seconds and then repeat
              waitForProcessingAction l actionType processingEventsCountAction' shutdownAction (maxTimeout - (Seconds 5))

    startEventTriggerPollerThread logger lockedEventsCtx cacheRef = do
      schemaCache <- liftIO $ getSchemaCache cacheRef
      let maxEventThreads = unrefine acEventsHttpPoolSize
          fetchInterval = milliseconds $ unrefine acEventsFetchInterval
          allSources = HM.elems $ scSources schemaCache

      unless (unrefine acEventsFetchBatchSize == 0 || fetchInterval == 0) $ do
        -- Don't start the events poller thread when fetchBatchSize or fetchInterval is 0
        -- prepare event triggers data
        eventEngineCtx <- liftIO $ atomically $ initEventEngineCtx maxEventThreads fetchInterval acEventsFetchBatchSize
        let eventsGracefulShutdownAction =
              waitForProcessingAction
                logger
                "event_triggers"
                (length <$> readTVarIO (leEvents lockedEventsCtx))
                (EventTriggerShutdownAction (shutdownEventTriggerEvents allSources logger lockedEventsCtx))
                (unrefine appEnvGracefulShutdownTimeout)

        -- Create logger for logging the statistics of events fetched
        fetchedEventsStatsLogger <-
          allocate
            (createFetchedEventsStatsLogger logger)
            (closeFetchedEventsStatsLogger logger)

        unLogger logger $ mkGenericLog @Text LevelInfo "event_triggers" "starting workers"
        void
          $ C.forkManagedTWithGracefulShutdown
            "processEventQueue"
            logger
            (C.ThreadShutdown (liftIO eventsGracefulShutdownAction))
          $ processEventQueue
            logger
            fetchedEventsStatsLogger
            appEnvManager
            (getSchemaCache cacheRef)
            eventEngineCtx
            lockedEventsCtx
            appEnvServerMetrics
            (pmEventTriggerMetrics appEnvPrometheusMetrics)
            appEnvEnableMaintenanceMode

    startAsyncActionsPollerThread logger lockedEventsCtx cacheRef actionSubState = do
      -- start a background thread to handle async actions
      case acAsyncActionsFetchInterval of
        Skip -> pure () -- Don't start the poller thread
        Interval (unrefine -> sleepTime) -> do
          let label = "asyncActionsProcessor"
              asyncActionGracefulShutdownAction =
                ( liftWithStateless \lowerIO ->
                    ( waitForProcessingAction
                        logger
                        "async_actions"
                        (length <$> readTVarIO (leActionEvents lockedEventsCtx))
                        (MetadataDBShutdownAction (hoist lowerIO (shutdownAsyncActions lockedEventsCtx)))
                        (unrefine appEnvGracefulShutdownTimeout)
                    )
                )

          void
            $ C.forkManagedTWithGracefulShutdown
              label
              logger
              (C.ThreadShutdown asyncActionGracefulShutdownAction)
            $ asyncActionsProcessor
              acEnvironment
              logger
              (getSchemaCache cacheRef)
              (leActionEvents lockedEventsCtx)
              appEnvPrometheusMetrics
              sleepTime
              Nothing

      -- start a background thread to handle async action live queries
      void $
        C.forkManagedT "asyncActionSubscriptionsProcessor" logger $
          asyncActionSubscriptionsProcessor actionSubState

    startScheduledEventsPollerThread logger lockedEventsCtx cacheRef = do
      -- prepare scheduled triggers
      lift $ prepareScheduledEvents logger

      -- Create logger for logging the statistics of scheduled events fetched
      scheduledEventsStatsLogger <-
        allocate
          (createFetchedScheduledEventsStatsLogger logger)
          (closeFetchedScheduledEventsStatsLogger logger)

      -- start a background thread to deliver the scheduled events
      -- _scheduledEventsThread <- do
      let scheduledEventsGracefulShutdownAction =
            ( liftWithStateless \lowerIO ->
                ( waitForProcessingAction
                    logger
                    "scheduled_events"
                    (getProcessingScheduledEventsCount lockedEventsCtx)
                    (MetadataDBShutdownAction (liftEitherM $ hoist lowerIO unlockAllLockedScheduledEvents))
                    (unrefine appEnvGracefulShutdownTimeout)
                )
            )

      void
        $ C.forkManagedTWithGracefulShutdown
          "processScheduledTriggers"
          logger
          (C.ThreadShutdown scheduledEventsGracefulShutdownAction)
        $ processScheduledTriggers
          acEnvironment
          logger
          scheduledEventsStatsLogger
          appEnvManager
          appEnvPrometheusMetrics
          (getSchemaCache cacheRef)
          lockedEventsCtx

instance (Monad m) => Tracing.HasReporter (PGMetadataStorageAppT m)

instance (Monad m) => HasResourceLimits (PGMetadataStorageAppT m) where
  askHTTPHandlerLimit = pure $ ResourceLimits id
  askGraphqlOperationLimit _ _ _ = pure $ ResourceLimits id

instance (MonadIO m) => HttpLog (PGMetadataStorageAppT m) where
  type ExtraHttpLogMetadata (PGMetadataStorageAppT m) = ()

  emptyExtraHttpLogMetadata = ()

  buildExtraHttpLogMetadata _ _ = ()

  logHttpError logger loggingSettings userInfoM reqId waiReq req qErr headers _ =
    unLogger logger $
      mkHttpLog $
        mkHttpErrorLogContext userInfoM loggingSettings reqId waiReq req qErr Nothing Nothing headers

  logHttpSuccess logger loggingSettings userInfoM reqId waiReq reqBody response compressedResponse qTime cType headers (CommonHttpLogMetadata rb batchQueryOpLogs, ()) =
    unLogger logger $
      mkHttpLog $
        mkHttpAccessLogContext userInfoM loggingSettings reqId waiReq reqBody (BL.length response) compressedResponse qTime cType headers rb batchQueryOpLogs

instance (Monad m) => MonadExecuteQuery (PGMetadataStorageAppT m) where
  cacheLookup _ _ _ _ = pure ([], Nothing)
  cacheStore _ _ _ = pure (Right CacheStoreSkipped)

instance (MonadIO m, MonadBaseControl IO m) => UserAuthentication (Tracing.TraceT (PGMetadataStorageAppT m)) where
  resolveUserInfo logger manager headers authMode reqs =
    runExceptT $ do
      (a, b, c) <- getUserInfoWithExpTime logger manager headers authMode reqs
      pure $ (a, b, c, ExtraUserInfo Nothing)

accessDeniedErrMsg :: Text
accessDeniedErrMsg =
  "restricted access : admin only"

instance (Monad m) => MonadMetadataApiAuthorization (PGMetadataStorageAppT m) where
  authorizeV1QueryApi query handlerCtx = runExceptT do
    let currRole = _uiRole $ hcUser handlerCtx
    when (requiresAdmin query && currRole /= adminRoleName) $
      withPathK "args" $
        throw400 AccessDenied accessDeniedErrMsg

  authorizeV1MetadataApi _ handlerCtx = runExceptT do
    let currRole = _uiRole $ hcUser handlerCtx
    when (currRole /= adminRoleName) $
      withPathK "args" $
        throw400 AccessDenied accessDeniedErrMsg

  authorizeV2QueryApi _ handlerCtx = runExceptT do
    let currRole = _uiRole $ hcUser handlerCtx
    when (currRole /= adminRoleName) $
      withPathK "args" $
        throw400 AccessDenied accessDeniedErrMsg

instance (Monad m) => ConsoleRenderer (PGMetadataStorageAppT m) where
  renderConsole path authMode enableTelemetry consoleAssetsDir consoleSentryDsn =
    return $ mkConsoleHTML path authMode enableTelemetry consoleAssetsDir consoleSentryDsn

instance (Monad m) => MonadVersionAPIWithExtraData (PGMetadataStorageAppT m) where
  getExtraDataForVersionAPI = return []

instance (Monad m) => MonadGQLExecutionCheck (PGMetadataStorageAppT m) where
  checkGQLExecution userInfo _ enableAL sc query _ = runExceptT $ do
    req <- toParsed query
    checkQueryInAllowlist enableAL AllowlistModeGlobalOnly userInfo req sc
    return req

  executeIntrospection _ introspectionQuery _ =
    pure $ Right $ ExecStepRaw introspectionQuery

  checkGQLBatchedReqs _ _ _ _ = runExceptT $ pure ()

instance (MonadIO m, MonadBaseControl IO m) => MonadConfigApiHandler (PGMetadataStorageAppT m) where
  runConfigApiHandler = configApiGetHandler

instance (MonadIO m) => MonadQueryLog (PGMetadataStorageAppT m) where
  logQueryLog logger = unLogger logger

instance (MonadIO m) => WS.MonadWSLog (PGMetadataStorageAppT m) where
  logWSLog logger = unLogger logger

instance (Monad m) => MonadResolveSource (PGMetadataStorageAppT m) where
  getPGSourceResolver = (mkPgSourceResolver . _lsPgLogger . appEnvLoggers) <$> asks snd
  getMSSQLSourceResolver = return mkMSSQLSourceResolver

instance (Monad m) => EB.MonadQueryTags (PGMetadataStorageAppT m) where
  createQueryTags _attributes _qtSourceConfig = return $ emptyQueryTagsComment

instance (Monad m) => MonadEventLogCleanup (PGMetadataStorageAppT m) where
  runLogCleaner _ = pure $ throw400 NotSupported "Event log cleanup feature is enterprise edition only"
  generateCleanupSchedules _ _ _ = pure $ Right ()
  updateTriggerCleanupSchedules _ _ _ _ = pure $ Right ()

runInSeparateTx ::
  (MonadIO m) =>
  PG.TxE QErr a ->
  PGMetadataStorageAppT m (Either QErr a)
runInSeparateTx tx = do
  pool <- appEnvMetadataDbPool <$> asks snd
  liftIO $ runExceptT $ PG.runTx pool (PG.RepeatableRead, Nothing) tx

notifySchemaCacheSyncTx :: MetadataResourceVersion -> InstanceId -> CacheInvalidations -> PG.TxE QErr ()
notifySchemaCacheSyncTx (MetadataResourceVersion resourceVersion) instanceId invalidations = do
  PG.Discard () <-
    PG.withQE
      defaultTxErrorHandler
      [PG.sql|
      INSERT INTO hdb_catalog.hdb_schema_notifications(id, notification, resource_version, instance_id)
      VALUES (1, $1::json, $2, $3::uuid)
      ON CONFLICT (id) DO UPDATE SET
        notification = $1::json,
        resource_version = $2,
        instance_id = $3::uuid
    |]
      (PG.ViaJSON invalidations, resourceVersion, instanceId)
      True
  pure ()

getCatalogStateTx :: PG.TxE QErr CatalogState
getCatalogStateTx =
  mkCatalogState . PG.getRow
    <$> PG.withQE
      defaultTxErrorHandler
      [PG.sql|
    SELECT hasura_uuid::text, cli_state::json, console_state::json
      FROM hdb_catalog.hdb_version
  |]
      ()
      False
  where
    mkCatalogState (dbId, PG.ViaJSON cliState, PG.ViaJSON consoleState) =
      CatalogState dbId cliState consoleState

setCatalogStateTx :: CatalogStateType -> A.Value -> PG.TxE QErr ()
setCatalogStateTx stateTy stateValue =
  case stateTy of
    CSTCli ->
      PG.unitQE
        defaultTxErrorHandler
        [PG.sql|
        UPDATE hdb_catalog.hdb_version
           SET cli_state = $1
      |]
        (Identity $ PG.ViaJSON stateValue)
        False
    CSTConsole ->
      PG.unitQE
        defaultTxErrorHandler
        [PG.sql|
        UPDATE hdb_catalog.hdb_version
           SET console_state = $1
      |]
        (Identity $ PG.ViaJSON stateValue)
        False

-- | Each of the function in the type class is executed in a totally separate transaction.
instance (MonadIO m) => MonadMetadataStorage (PGMetadataStorageAppT m) where
  fetchMetadataResourceVersion = runInSeparateTx fetchMetadataResourceVersionFromCatalog
  fetchMetadata = runInSeparateTx fetchMetadataAndResourceVersionFromCatalog
  fetchMetadataNotifications a b = runInSeparateTx $ fetchMetadataNotificationsFromCatalog a b
  setMetadata r = runInSeparateTx . setMetadataInCatalog r
  notifySchemaCacheSync a b c = runInSeparateTx $ notifySchemaCacheSyncTx a b c
  getCatalogState = runInSeparateTx getCatalogStateTx
  setCatalogState a b = runInSeparateTx $ setCatalogStateTx a b

  getMetadataDbUid = runInSeparateTx getDbId
  checkMetadataStorageHealth = runInSeparateTx $ checkDbConnection

  getDeprivedCronTriggerStats = runInSeparateTx . getDeprivedCronTriggerStatsTx
  getScheduledEventsForDelivery = runInSeparateTx getScheduledEventsForDeliveryTx
  insertCronEvents = runInSeparateTx . insertCronEventsTx
  insertOneOffScheduledEvent = runInSeparateTx . insertOneOffScheduledEventTx
  insertScheduledEventInvocation a b = runInSeparateTx $ insertInvocationTx a b
  setScheduledEventOp a b c = runInSeparateTx $ setScheduledEventOpTx a b c
  unlockScheduledEvents a b = runInSeparateTx $ unlockScheduledEventsTx a b
  unlockAllLockedScheduledEvents = runInSeparateTx unlockAllLockedScheduledEventsTx
  clearFutureCronEvents = runInSeparateTx . dropFutureCronEventsTx
  getOneOffScheduledEvents a b c = runInSeparateTx $ getOneOffScheduledEventsTx a b c
  getCronEvents a b c d = runInSeparateTx $ getCronEventsTx a b c d
  getScheduledEventInvocations a = runInSeparateTx $ getScheduledEventInvocationsTx a
  deleteScheduledEvent a b = runInSeparateTx $ deleteScheduledEventTx a b

  insertAction a b c d = runInSeparateTx $ insertActionTx a b c d
  fetchUndeliveredActionEvents = runInSeparateTx fetchUndeliveredActionEventsTx
  setActionStatus a b = runInSeparateTx $ setActionStatusTx a b
  fetchActionResponse = runInSeparateTx . fetchActionResponseTx
  clearActionData = runInSeparateTx . clearActionDataTx
  setProcessingActionLogsToPending = runInSeparateTx . setProcessingActionLogsToPendingTx

instance MonadIO m => MonadMetadataStorageQueryAPI (PGMetadataStorageAppT m)

--- helper functions ---

mkConsoleHTML :: Text -> AuthMode -> TelemetryStatus -> Maybe Text -> Maybe Text -> Either String Text
mkConsoleHTML path authMode enableTelemetry consoleAssetsDir consoleSentryDsn =
  renderHtmlTemplate consoleTmplt $
    -- variables required to render the template
    A.object
      [ "isAdminSecretSet" A..= isAdminSecretSet authMode,
        "consolePath" A..= consolePath,
        "enableTelemetry" A..= boolToText (isTelemetryEnabled enableTelemetry),
        "cdnAssets" A..= boolToText (isNothing consoleAssetsDir),
        "consoleSentryDsn" A..= fromMaybe "" consoleSentryDsn,
        "assetsVersion" A..= consoleAssetsVersion,
        "serverVersion" A..= currentVersion,
        "consoleSentryDsn" A..= ("" :: Text)
      ]
  where
    consolePath = case path of
      "" -> "/console"
      r -> "/console/" <> r

    consoleTmplt = $(makeRelativeToProject "src-rsr/console.html" >>= M.embedSingleTemplate)

telemetryNotice :: Text
telemetryNotice =
  "Help us improve Hasura! The graphql-engine server collects anonymized "
    <> "usage stats which allows us to keep improving Hasura at warp speed. "
    <> "To read more or opt-out, visit https://hasura.io/docs/latest/graphql/core/guides/telemetry.html"

mkPgSourceResolver :: PG.PGLogger -> SourceResolver ('Postgres 'Vanilla)
mkPgSourceResolver pgLogger env _ config = runExceptT do
  let PostgresSourceConnInfo urlConf poolSettings allowPrepare isoLevel _ = _pccConnectionInfo config
  -- If the user does not provide values for the pool settings, then use the default values
  let (maxConns, idleTimeout, retries) = getDefaultPGPoolSettingIfNotExists poolSettings defaultPostgresPoolSettings
  urlText <- resolveUrlConf env urlConf
  let connInfo = PG.ConnInfo retries $ PG.CDDatabaseURI $ txtToBs urlText
      connParams =
        PG.defaultConnParams
          { PG.cpIdleTime = idleTimeout,
            PG.cpConns = maxConns,
            PG.cpAllowPrepare = allowPrepare,
            PG.cpMbLifetime = _ppsConnectionLifetime =<< poolSettings,
            PG.cpTimeout = _ppsPoolTimeout =<< poolSettings
          }
  pgPool <- liftIO $ Q.initPGPool connInfo connParams pgLogger
  let pgExecCtx = mkPGExecCtx isoLevel pgPool NeverResizePool
  pure $ PGSourceConfig pgExecCtx connInfo Nothing mempty (_pccExtensionsSchema config) mempty Nothing

mkMSSQLSourceResolver :: SourceResolver ('MSSQL)
mkMSSQLSourceResolver env _name (MSSQLConnConfiguration connInfo _) = runExceptT do
  let MSSQLConnectionInfo iConnString MSSQLPoolSettings {..} = connInfo
      connOptions =
        MSPool.ConnectionOptions
          { _coConnections = fromMaybe defaultMSSQLMaxConnections _mpsMaxConnections,
            _coStripes = 1,
            _coIdleTime = _mpsIdleTimeout
          }
  (connString, mssqlPool) <- createMSSQLPool iConnString connOptions env
  let mssqlExecCtx = mkMSSQLExecCtx mssqlPool NeverResizePool
  pure $ MSSQLSourceConfig connString mssqlExecCtx
