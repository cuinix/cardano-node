{-# LANGUAGE OverloadedStrings #-}

module Cardano.Tracer.Handlers.Logs.Utils
  ( createOrUpdateEmptyLog
  , createEmptyLogRotation
  , getTimeStampFromLog
  , isItLog
  , logExtension
  , logPrefix
  , timeStampFormat
  ) where

import           Cardano.Tracer.Configuration (LogFormat (..), LoggingParams (..))
import           Cardano.Tracer.Types (HandleRegistry, HandleRegistryKey)
import           Cardano.Tracer.Utils (modifyRegistry_)

import           Control.Concurrent.Extra (Lock, withLock)
import           Control.Exception (Handler (..), IOException, catches, throwIO)
import           Data.Foldable (for_)
import qualified Data.Map as Map
import           Data.Maybe (isJust)
import qualified Data.Text as T
import           Data.Time.Clock (UTCTime)
import           Data.Time.Clock.System (getSystemTime, systemToUTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import           System.Directory
import           System.FilePath (takeBaseName, takeExtension, takeFileName, (<.>), (</>))
import           System.IO (IOMode (WriteMode), hClose, openFile)
import           System.IO.Error (isDoesNotExistError)


logPrefix :: String
logPrefix = "node-"

logExtension :: LogFormat -> String
logExtension ForHuman   = ".log"
logExtension ForMachine = ".json"

symLinkName :: LogFormat -> FilePath
symLinkName format = "node" <.> logExtension format

-- | An example of the valid log name: 'node-2021-11-29T09-55-04.json'.
isItLog :: LogFormat -> FilePath -> Bool
isItLog format pathToLog = hasProperPrefix && hasTimestamp && hasProperExt
 where
  fileName = takeFileName pathToLog
  hasProperPrefix = T.pack logPrefix `T.isPrefixOf` T.pack fileName
  hasTimestamp = isJust timeStamp
  hasProperExt = takeExtension fileName == logExtension format

  timeStamp :: Maybe UTCTime
  timeStamp = parseTimeM True defaultTimeLocale timeStampFormat $ T.unpack maybeTimestamp

  maybeTimestamp = T.drop (length logPrefix) . T.pack . takeBaseName $ fileName

createEmptyLogRotation
  :: Lock
  -> HandleRegistryKey
  -> HandleRegistry
  -> FilePath
  -> IO ()
createEmptyLogRotation currentLogLock key registry subDirForLogs = do
  -- The root directory (as a parent for subDirForLogs) will be created as well if needed.
  createDirectoryIfMissing True subDirForLogs
  createOrUpdateEmptyLog currentLogLock key registry subDirForLogs

-- | Create an empty log file (with the current timestamp in the name).
createOrUpdateEmptyLog :: Lock -> HandleRegistryKey -> HandleRegistry -> FilePath -> IO ()
createOrUpdateEmptyLog currentLogLock key@(_, LoggingParams{logFormat = format}) registry subDirForLogs = do
  withLock currentLogLock do
    ts <- formatTime defaultTimeLocale timeStampFormat . systemToUTCTime <$> getSystemTime
    let pathToLog = subDirForLogs </> logPrefix <> ts <.> logExtension format

    modifyRegistry_ registry \handles -> do

      for_ @Maybe (Map.lookup key handles) \(handle, _filePath) ->
        hClose handle

      newHandle <- openFile pathToLog WriteMode
      updateSymlinkAtomically format subDirForLogs pathToLog
      let newMap = Map.insert key (newHandle, pathToLog) handles
      pure newMap

-- this should be part of the atomical section that opens a new file;
-- thus, updating the symlink becomes atomical, too.
updateSymlinkAtomically :: LogFormat -> FilePath -> FilePath -> IO ()
updateSymlinkAtomically format subDirForLogs pathToLog = do
  removeFile symlinkTmp
    `catches` [ Handler $ \(e :: IOException) -> if isDoesNotExistError e then pure () else throwIO e ] -- in case the temp file isn't there, don't rethrow
  createFileLink pathToLog symlinkTmp
  renamePath symlinkTmp symlink
  where
    symlink     = subDirForLogs </> symLinkName format
    symlinkTmp  = symlink <.> "tmp"

getTimeStampFromLog :: FilePath -> Maybe UTCTime
getTimeStampFromLog pathToLog =
  parseTimeM True defaultTimeLocale timeStampFormat timeStamp
 where
  timeStamp = drop (length logPrefix) . takeBaseName . takeFileName $ pathToLog

timeStampFormat :: String
timeStampFormat = "%Y-%m-%dT%H-%M-%S"
