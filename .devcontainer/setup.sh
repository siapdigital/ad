#!/bin/bash
echo "Installing go-agy-ide..."
curl -fsSL https://raw.githubusercontent.com/sodikinnaa/go-agy-ide/main/install.sh | bash

if [ ! -f password.txt ]; then
    echo "siapdigital123" > password.txt
fi

echo "Starting mobile-agy server on port 8090..."
PASSWORD=$(cat password.txt) PORT=8090 nohup ./mobile-agy > mobile-agy.log 2>&1 &
echo "mobile-agy started successfully!"
