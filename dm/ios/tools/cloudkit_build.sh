# iCloud through CloudKit for the iPhone and Apple TV apps (docs/cloudkit-saves.md; Sources/SaveBackend.swift), sourced by build_ipa.sh, which calls the two functions below.
# DM_CLOUDKIT_CONTAINER=iCloud.<id>: the container the Mac, iPhone and Apple TV apps share. Its Info.plist key turns the settings' iCloud choice on, and the entitlements ask for
# it; the app must then be signed with a paid Apple developer account whose profile for the app's bundle ID has iCloud (CloudKit) and that container (else the settings say why).
ck_container() {
  [ -n "${DM_CLOUDKIT_CONTAINER:-}" ] || return 1
  case "$DM_CLOUDKIT_CONTAINER" in iCloud.*) return 0;; *) echo "DM_CLOUDKIT_CONTAINER=$DM_CLOUDKIT_CONTAINER: an iCloud container identifier is iCloud.<reverse DNS>" >&2; exit 1;; esac
}
ck_info() {   # <Info.plist>
  ck_container || return 0
  /usr/libexec/PlistBuddy -c "Add :DMCloudKitContainer string $DM_CLOUDKIT_CONTAINER" "$1" > /dev/null || { echo "DMCloudKitContainer in $1" >&2; exit 1; }
  echo "iCloud (CloudKit): container $DM_CLOUDKIT_CONTAINER"
}
ck_entitlements() {   # <entitlements plist>
  ck_container || return 0
  local f=$1 pb=/usr/libexec/PlistBuddy
  $pb -c "Delete :com.apple.developer.icloud-container-identifiers" "$f" > /dev/null 2>&1
  $pb -c "Delete :com.apple.developer.icloud-services" "$f" > /dev/null 2>&1
  $pb -c "Add :com.apple.developer.icloud-container-identifiers array" -c "Add :com.apple.developer.icloud-container-identifiers:0 string $DM_CLOUDKIT_CONTAINER" \
      -c "Add :com.apple.developer.icloud-services array" -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "$f" > /dev/null || { echo "iCloud entitlements in $f" >&2; exit 1; }
}
