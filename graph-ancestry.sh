#!/bin/bash

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

basename="ancestry-graph"

echo ruby ~/graph-ancestry.rb -d $GRAPH_ANCESTRY_DIR --contract "(^|origin/)$GRAPH_ANCESTRY_TEAM_NAME" '>' "${basename}.dot"
ruby ~/graph-ancestry.rb -d "$GRAPH_ANCESTRY_DIR" --contract "(^|origin/)$GRAPH_ANCESTRY_TEAM_NAME" > "${basename}.dot" || exit

echo dot -Tpdf '<' "${basename}.dot" '>' "${basename}.pdf"
dot -Tpdf < "${basename}.dot" > "${basename}.pdf" || exit

echo open "${basename}.pdf"
open "${basename}.pdf" || exit
