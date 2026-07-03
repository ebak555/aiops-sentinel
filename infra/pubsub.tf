resource "google_pubsub_topic" "aiops_alerts" {
  name = "aiops-alerts"
}

resource "google_pubsub_topic" "aiops_incidents" {
  name = "aiops-incidents"
}

# Without this, a subscriber that fails (bug, bad message, or -- as
# happened in practice -- the downstream Anthropic API account running out
# of credit) causes Pub/Sub to redeliver the same message every few
# seconds forever, since there's no other backstop. That silently turned
# into thousands of retried Cloud Run invocations (and, before that,
# repeated real Claude API calls) for a handful of actual incidents.
resource "google_pubsub_topic" "aiops_dead_letter" {
  name = "aiops-dead-letter"
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  topic  = google_pubsub_topic.aiops_dead_letter.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
