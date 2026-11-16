#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp -t iina-nas-tests)
trap 'rm -f "$binary"' EXIT
swiftc -parse-as-library iina/NAS/NASModels.swift iina/NAS/JellyfinClient.swift Tests/NAS/NASRegression.swift -o "$binary"
"$binary"
swiftc -parse-as-library iina/NAS/NASModels.swift iina/NAS/NASQueue.swift iina/FolderPlaylistImporter.swift Tests/NAS/FolderDropRegression.swift -o "$binary"
"$binary"
swiftc -parse-as-library iina/Regex.swift iina/GeometryDef.swift Tests/NAS/GeometryRegression.swift -o "$binary"
"$binary"
swiftc -parse-as-library iina/NAS/NASModels.swift iina/NAS/NASQueue.swift iina/NAS/JellyfinClient.swift iina/NAS/JellyfinPlayback.swift Tests/NAS/PlaybackRegression.swift -o "$binary"
"$binary"
