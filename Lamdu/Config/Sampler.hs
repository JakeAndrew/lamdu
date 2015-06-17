module Lamdu.Config.Sampler
    ( Sampler, new
    , Version, getConfig
    ) where

import           Control.Applicative ((<$>))
import           Control.Concurrent (threadDelay, forkIO, ThreadId)
import           Control.Concurrent.MVar
import qualified Control.Exception as E
import           Control.Monad (forever)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import           Lamdu.Config (Config)
import           Lamdu.DataFile (accessDataFile)

type Version = Int

data Sampler a = Sampler
    { _sThreadId :: ThreadId
    , sGetConfig :: IO (Version, a)
    }

getConfig :: Sampler a -> IO (Version, a)
getConfig = sGetConfig

sampler :: Eq a => IO a -> IO (Sampler a)
sampler sample =
    do
        ref <- newMVar . (,) 0 =<< E.evaluate =<< sample
        let updateMVar newSample =
                modifyMVar_ ref $ \(ver, oldSample) -> return $
                if oldSample == newSample
                then (ver, oldSample)
                else (ver+1, newSample)
        tid <-
            forkIO . forever $
            do
                threadDelay 200000
                (updateMVar =<< sample) `E.catch` \E.SomeException {} -> return ()
        return $ Sampler tid $ readMVar ref

load :: FilePath -> IO Config
load configPath =
    do
        eConfig <- Aeson.eitherDecode' <$> LBS.readFile configPath
        either (fail . (msg ++)) return eConfig
    where
        msg = "Failed to parse config file contents at " ++ show configPath ++ ": "

new :: FilePath -> IO (Sampler Config)
new startDir = sampler $ accessDataFile startDir load "config.json"