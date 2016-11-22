module Main where

import Network hiding (accept, sClose)
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import System.Environment
import System.IO
import Data.ByteString.Char8 (pack, unpack)
import Control.Concurrent {- hiding (forkFinally) instead using myFOrkFinally to avoid GHC version issues-}
import Control.Concurrent.STM
import Control.Exception
import Control.Applicative ((<$>), (<*>))
import Control.Monad (forever, when, join, mapM, mapM_, forM, forM_, sequence, sequence_)
import Data.List.Split
import qualified Data.Map as M hiding (split)
import Prelude hiding (null, lookup)
import Text.Printf (printf)

{-
    Types
-}
--type uuid = Integer
--type address = String
--type port = String
--type filename = String
--type timestamp = Double

{-
	FileServer
-}
data FileServer = FileServer
    { uuid		:: String
	, address	:: String
	, port		:: Integer
	}
{-
    DirectoryServer
-}
data DirectoryServer = DirectoryServer
    { address         :: String
    , port            :: String
    , fileservers    :: TVar (M.Map uuid address port)
    , filemappings   :: TVar (M.Map filename uuid address port timestamp)
    }

newDirectoryServer :: String -> String -> IO ChatServer
newDirectoryServer address port = atomically $ do
    DirectoryServer <$> return address <*> return port <*> newTVar M.empty <*> newTVar M.empty 

main:: IO ()
main = withSocketsDo $ do

    server <- newDirectoryServer serverhost serverport

    addrinfos <- getAddrInfo
			 (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
			 Nothing (Just serverport)

    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    bindSocket sock (addrAddress serveraddr)
    listen sock 5

    _ <- printf "Listening on port %s\n" serverport

    threadCount <- atomically $ newTVar 0
	--New Abstract FIFO Channel
    chan <- newChan
	--Spawns a new thread to handle the clientconnectHandler method, passes socket, channel, numThreads and server
    forkIO $ clientconnectHandler sock chan threadCount server
  
    --Calls the mainHandler which will monitor the FIFO channel
    mainHandler sock chan

mainHandler :: Socket -> Chan String -> IO ()
mainHandler sock chan = do

  --Read current message on the FIFO channel
  chanMsg <- readChan chan

  --If KILL_SERVICE, stop mainHandler running, If anything else, call mainHandler again, keeping the service running
  case (chanMsg) of
    ("KILL_SERVICE") -> putStrLn "Terminating the Service!"
    _ -> mainHandler sock chan

clientconnectHandler :: Socket -> Chan String -> TVar Int -> DirectoryServer -> IO ()
clientconnectHandler sock chan threadCount server = do

  (s,a) <- accept sock
  --Read numThreads from memory and print it on server console
  count <- atomically $ readTVar numThreads
  putStrLn $ "numThreads = " ++ show count

  --If there are still threads remaining create new thread and increment (exception if thread is lost -> decrement), else tell user capacity has been reached
  if (count < maxnumThreads) then do
    forkFinally (clientHandler s chan server numThreads) (\_ -> atomically $ decrementTVar numThreads)
    atomically $ incrementTVar numThreads
    else do
      hPutStrLn handle "Maximum number of threads in use. try again soon"
      hClose handle

  clientconnectHandler sock chan numThreads server

clientHandler :: Socket -> Chan String -> DirectoryServer -> IO ()
clientHandler sock chan server@DirectoryServer{..} =
    forever $ do
        message <- recv sock 1024
	let msg = unpack message
        --print $ msg ++ "!ENDLINE!"
        let cmd = head $ words $ head $ splitOn ":" msg
        print cmd
        case cmd of
            ("JOIN") -> joinCommand sock server msg
            ("CLOSE") -> closeCommand sock server msg
            ("READ") -> readCommand sock server msg
            ("WRITE") -> writeCommand sock server msg
            ("OPEN") -> openCommand sock server $ (words msg) !! 1
            ("KILL_SERVICE") -> killCommand chan sock
            _ -> do send sock (pack ("Unknown Command - " ++ msg ++ "\n\n")) ; return ()
       

joinCommand :: Socket -> DirectoryServer -> String -> IO ()
joinCommand sock server@DirectoryServer{..} command = do

    let clines = splitOn "\\n" command
        nodeID = (splitOn ":" $ clines !! 0) !! 1
        address = (splitOn ":" $ clines !! 1) !! 1
        port = (splitOn ":" $ clines !! 2) !! 1

    if (nodeID == "") then do
        nodeID <- atomically $ readTVar FILESERVERJoinCount

     --fs <- atomically $ newFILESERVER nodeID address port
     --atomically $ addFILESERVERToServer server nodeID fs
     --atomically $ incrementFILESERVERJoinCount FILESERVERJoinCount

	modifyTVar fileservers . M.insert nodeID address port
	sendAll sock $ pack $
	    "RESPONSE:" ++ "JOIN" ++ "\n" ++ 
		"UUID:" ++ nodeID ++ "\n\n"
	
	return ()

closeCommand :: Socket -> DirectoryServer -> String -> IO ()
closeCommand sock server@DirectoryServer{..} command = do
    
    let clines = splitOn "\\n" command
        filename = (splitOn ":" $ clines !! 0) !! 1
        --address = (splitOn ":" $ clines !! 1) !! 1
        --port = (splitOn ":" $ clines !! 2) !! 1

    sendAll sock $ pack $
         "RESPONSE:" ++ "CLOSE" ++ "\n" ++ 
         "FILENAME:" ++ filename ++ "\n" ++
         "ISFILE:" ++ True ++ "\n\n" ; return ()
    
readCommand :: Socket -> DirectoryServer -> String -> IO ()
readCommand sock server@DirectoryServer{..} command = do
    
    let clines = splitOn "\\n" command
        filename = (splitOn ":" $ clines !! 0) !! 1
        --address = (splitOn ":" $ clines !! 1) !! 1
        --port = (splitOn ":" $ clines !! 2) !! 1
    if (fileExists filename) then do
	    
	    sendAll sock $ pack $
		 "RESPONSE:" ++ "READ" ++ "\n" ++ 
		 "FILENAME:" ++ filename ++ "\n" ++
		 "ISFILE:" ++ True ++ "\n" ++
		 "ADDRESS:" ++ M.lookup fm <$> readTVar address ++ "\n" ++
		 "PORT:" ++ M.lookup fm <$> readTVar port ++ "\n" ++
		 "TIMESTAMP:" ++ M.lookup fm <$> readTVar timestamp ++ "\n\n"
    else then do
        sendAll sock $ pack $
		 "RESPONSE:" ++ "READ-NULL" ++ "\n" ++ 
		 "FILENAME:" ++ filename ++ "\n" ++
		 "ISFILE:" ++ False ++ "\n\n"
    return()

writeCommand :: Socket -> DirectoryServer -> String -> IO ()
writeCommand sock server@DirectoryServer{..} command = do
    
    let clines = splitOn "\\n" command
        filename = (splitOn ":" $ clines !! 0) !! 1
        timestamp = (splitOn ":" $ clines !! 1) !! 1
        --port = (splitOn ":" $ clines !! 2) !! 1

    if (fileExists filename) then do
	    sendAll sock $ pack $
		 "RESPONSE:" ++ "WRITE-EXISTS" ++ "\n" ++ 
		 "FILENAME:" ++ filename ++ "\n" ++
		 "ISFILE:" ++ True ++ "\n" ++
         "UUID:" ++ (getID filename) ++ "\n" ++
		 "ADDRESS:" ++ (getAddress filename) ++ "\n" ++
		 "PORT:" ++ (getPort filename) ++ "\n" ++
		 "TIMESTAMP:" ++ (getTimestamp filename) ++ "\n\n"
    else then do
        --get random fileserver
		fs = head $ Map.keys fileservers
		nodeID = M.lookup fs <$> readTVar uuid
		address = M.lookup fs <$> readTVar address
		port = M.lookup fs <$> readTVar port
		modifyTVar filemappings . M.insert filename nodeID address port timestamp
        sendAll sock $ pack $
		 "RESPONSE:" ++ "READ-NULL" ++ "\n" ++ 
		 "FILENAME:" ++ filename ++ "\n" ++
		 "ISFILE:" ++ False ++ "\n" ++
		 "UUID:" ++ nodeID ++ "\n" ++
		 "ADDRESS:" ++ address ++ "\n" ++
		 "PORT:" ++ port ++ "\n" ++
		 "TIMESTAMP:" ++ timestamp ++ "\n\n"
    
    return()


serverport :: String
serverport = "7007"

serverhost :: String
serverhost = "192.168.6.129"

incrementTVar :: TVar Int -> STM ()
incrementTVar tv = modifyTVar tv ((+) 1)

decrementTVar :: TVar Int -> STM ()
decrementTVar tv = modifyTVar tv (subtract 1)
