assert_account() {
  local p=$1 e=$2 a
  a=$(aws sts get-caller-identity --profile "$p" --query Account --output text)
  [[ "$a" == "$e" ]] || { echo "STOP: $p -> $a, oczekiwano $e"; return 1; }
  echo "OK: $p -> $a"
}
assert_account "$PROFILE_DEV" "$DEV_ACCOUNT"
assert_account "$PROFILE_PROD" "$PROD_ACCOUNT"
assert_account "$PROFILE_GENERAL" "$GENERAL_ACCOUNT"