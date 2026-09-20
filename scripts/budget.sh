#!/usr/bin/env bash
cat > /tmp/notif.json <<EOF
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "$BUDGET_EMAIL" } ]
  },
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "$BUDGET_EMAIL" } ]
  }
]
EOF

for PAIR in "development:$DEV_ACCOUNT" "production:$PROD_ACCOUNT"; do
  NAME="${PAIR%%:*}"; ACC="${PAIR##*:}"
  cat > /tmp/budget.json <<EOF
{ "BudgetName": "${PREFIX}-limit-${NAME}",
  "BudgetLimit": {"Amount": "5", "Unit": "USD"},
  "TimeUnit": "MONTHLY", "BudgetType": "COST",
  "CostFilters": { "LinkedAccount": ["$ACC"] } }
EOF
  aws budgets create-budget --profile "$PROFILE_GENERAL" \
    --account-id "$GENERAL_ACCOUNT" \
    --budget file:///tmp/budget.json \
    --notifications-with-subscribers file:///tmp/notif.json
done