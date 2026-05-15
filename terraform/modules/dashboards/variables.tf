variable "name_prefix"         { type = string }
variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "app_insights_id" {
  type        = string
  description = "App Insights resource ID — used as the workbook's source_id (lowercased per provider validation)."
}
variable "tags" {
  type    = map(string)
  default = {}
}
