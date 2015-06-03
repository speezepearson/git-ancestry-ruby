#!/bin/bash

HERE=`dirname "$BASH_SOURCE"`

if [ -f ~/.bash_profile ]; then
    source ~/.bash_profile
fi

if [ "$1" ]; then
    GRAPH_ANCESTRY_TEAM_NAME="$1"
elif [ ! "$GRAPH_ANCESTRY_TEAM_NAME" ]; then
    echo "error: no argument given and no GRAPH_ANCESTRY_TEAM_NAME in env"
fi

if [ "$2" ]; then
    GRAPH_ANCESTRY_DIR="$2"
elif [ ! "$GRAPH_ANCESTRY_DIR" ]; then
    GRAPH_ANCESTRY_DIR='.'
fi

FILE=`mktemp ancestry-graph.XXX`
ruby "$HERE/graph-ancestry.rb" -d "$GRAPH_ANCESTRY_DIR" --prefix "$GRAPH_ANCESTRY_TEAM_NAME" --contract > "$FILE.dot" || exit 1
dot -Tpdf < "$FILE.dot" > "$FILE.pdf" || exit 1
open -W -a '/Applications/Preview.app' "$FILE.pdf"
rm "$FILE"{,.dot,.pdf}

