--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

module Main where

import Ogmios.Prelude

import Ogmios
    ( Command (..)
    , Options (..)
    , application
    , newEnvironment
    , parseOptions
    , runWith
    , version
    , withStdoutTracer
    )

main :: IO ()
main = parseOptions >>= \case
    Version -> do
        putTextLn version
    Start (Identity network) opts@Options{logLevel} -> do
        withStdoutTracer version logLevel $ \tr -> do
            env <- newEnvironment tr network opts
            application tr `runWith` env
