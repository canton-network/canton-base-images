umask 022
JAVA_HOME=/usr/java
PS1='\[\e[0;32m\]\u@\h:\[\e[0;34m\]\w\[\e[0m\]$ '

IMAGE_PATHS=/usr/bin:/bin:/usr/java/bin
if [ -n "$PATH" ]; then
    export PATH=$IMAGE_PATHS:$PATH
else
    export PATH=$IMAGE_PATHS
fi

export LC_ALL PATH JAVA_HOME
