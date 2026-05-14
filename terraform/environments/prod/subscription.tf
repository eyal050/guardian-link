# Subscription was created via a one-time Stage 0 bootstrap and lives at
# var.workload_subscription_id. The ADO SP lacks Microsoft.Subscription/aliases/*
# permissions, so any pipeline plan that tried to refresh azurerm_subscription.main
# would fail with 401. The removed block keeps the subscription alive in Azure
# while taking it out of Terraform's management surface — same pattern as
# environments/dev.
#
# Future fresh deploys: temporarily add a `resource "azurerm_subscription" "main"`
# block, run with user `az` creds (Microsoft.Subscription/aliases/write), then
# replace the resource block with this removed block and `terraform state rm`
# the resource before the next pipeline run.
removed {
  from = azurerm_subscription.main
  lifecycle {
    destroy = false
  }
}

resource "azurerm_management_group_subscription_association" "main" {
  count = var.management_group_id == null ? 0 : 1

  management_group_id = var.management_group_id
  subscription_id     = "/subscriptions/${var.workload_subscription_id}"
}
