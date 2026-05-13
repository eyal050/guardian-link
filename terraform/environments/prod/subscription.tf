# Prod manages its own subscription. First-time deploy:
#   1. Run ./run.sh stage0 with your own `az login` credentials
#      (the ADO SP lacks Microsoft.Subscription/aliases/write).
#   2. Capture the printed subscription_id and set TF_VAR_workload_subscription_id
#      (or workload_subscription_id in tfvars) for subsequent runs.
# After Stage 0, the subscription is in state and azurerm.workload uses it
# directly when var.workload_subscription_id is empty.
resource "azurerm_subscription" "main" {
  subscription_name = var.new_subscription_name
  billing_scope_id  = var.billing_scope_id
  tags              = local.tags
}

resource "azurerm_management_group_subscription_association" "main" {
  count = var.management_group_id == null ? 0 : 1

  management_group_id = var.management_group_id
  subscription_id     = "/subscriptions/${azurerm_subscription.main.subscription_id}"
}
