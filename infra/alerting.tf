# Baseline alerting for the golden signals collected by the blackbox prober.
#
# Deliberately tight/noisy thresholds on purpose: Phase 3's correlation
# layer is built to solve the alert-fatigue problem these create, so the
# noise here is the point, not a bug.
#
# Implemented as Cloud Monitoring alert policies with PromQL conditions
# (queried directly against the GMP/Monarch backend) rather than a
# self-hosted Prometheus Alertmanager, since this cluster's free-tier disk
# quota only fits 2 nodes and both are already near capacity — this adds
# zero extra pods.

# Cloud Monitoring's webhook_basicauth channel type POSTs the alert JSON
# payload to `url` using HTTP Basic Auth, which matches how the Cloud Run
# alert-receiver service (services/alert-receiver) authenticates requests.
resource "google_monitoring_notification_channel" "alert_receiver" {
  project      = var.project_id
  display_name = "AIOps Sentinel alert receiver (Cloud Run)"
  type         = "webhook_basicauth"

  labels = {
    url      = "${google_cloud_run_v2_service.alert_receiver.uri}/webhook"
    username = "aiops"
  }

  sensitive_labels {
    password = random_password.alert_webhook_password.result
  }
}

resource "google_monitoring_alert_policy" "frontend_probe_failed" {
  project      = var.project_id
  display_name = "AIOps Sentinel: frontend probe failing"
  combiner     = "OR"

  conditions {
    display_name = "probe_success == 0"
    condition_prometheus_query_language {
      query    = "probe_success == 0"
      duration = "60s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.alert_receiver.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "frontend_latency_high" {
  project      = var.project_id
  display_name = "AIOps Sentinel: frontend latency above 200ms"
  combiner     = "OR"

  conditions {
    display_name = "probe_duration_seconds > 0.2"
    condition_prometheus_query_language {
      query    = "probe_duration_seconds > 0.2"
      duration = "60s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.alert_receiver.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "frontend_non_200" {
  project      = var.project_id
  display_name = "AIOps Sentinel: frontend returning non-200"
  combiner     = "OR"

  conditions {
    display_name = "probe_http_status_code != 200"
    condition_prometheus_query_language {
      query    = "probe_http_status_code != 200"
      duration = "60s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.alert_receiver.id]

  alert_strategy {
    auto_close = "1800s"
  }
}
