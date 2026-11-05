@echo off
set "NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node"
set "DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk"
set "JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr"
set "PATH=C:\Program Files\Huawei\DevEco Studio\jbr\bin;C:\Program Files\Huawei\DevEco Studio\tools\node;%PATH%"
cd /d "C:\Users\zhang\SpektraLabHarmony"
call "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" %*
