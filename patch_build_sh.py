with open("build_app.sh", "r") as f:
    content = f.read()

content = content.replace('cp -R "$BUILD_DIR/$BUNDLE_NAME" "$APP_BUNDLE/Contents/Resources/"',
'''cp -R "$BUILD_DIR/$BUNDLE_NAME" "$APP_BUNDLE/Contents/Resources/"
    # Workaround for SPM generated resource accessor in CLI tools looking in bundleURL root
    cp -R "$BUILD_DIR/$BUNDLE_NAME" "$APP_BUNDLE/"
    cp -R "$BUILD_DIR/$BUNDLE_NAME" "$APP_BUNDLE/Contents/MacOS/"''')

with open("build_app.sh", "w") as f:
    f.write(content)
