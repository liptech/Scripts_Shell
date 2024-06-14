#!/bin/bash

# Remove the Joplin AppImage
echo "Removing Joplin AppImage..."
rm -f ~/.joplin/Joplin.AppImage

#Remove atalho
echo "Remove Atalho do gnome"
rm -rf ~/.local/share/applications/appimagekit-joplin.desktop

# Remove the version file
echo "Removing Joplin version file..."
rm -f ~/.joplin/VERSION

# Remove the desktop icon
echo "Removing Joplin desktop icon..."
sudo rm /usr/share/applications/joplin.desktop

# Remove Joplin configuration and data directories
echo "Removing Joplin configuration and data directories..."
rm -rf ~/.joplin
rm -rf ~/.config/joplin-desktop

# Remove the local share icon
echo "Removing Joplin local share icon..."
rm -f ~/.local/share/icons/hicolor/512x512/apps/joplin.png

echo "Joplin has been successfully removed."

