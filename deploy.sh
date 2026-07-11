#!/bin/bash
set -e

./bundle-wine.sh --runtime-only --dest "/Applications/TurtleWoW.app/Contents/Resources/"
./bundle-wine.sh --dest "/Users/alex/Developer/wine/dist"
