#!/bin/sh
set -e

npm run migrate
exec node src/server.js
