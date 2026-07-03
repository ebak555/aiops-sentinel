package main

import rego.v1

# Bounds tied to this project's actual free-tier constraint: the 2-node
# disk quota (see README) leaves very little CPU/memory headroom, so a
# proposed fix that requests too much would risk repeating the Phase 1/2
# capacity incidents rather than fixing anything. A PR that stays within
# these bounds auto-merges; anything else requires human review.

cpu_millis(v) := m if {
	endswith(v, "m")
	m := to_number(trim_suffix(v, "m"))
}

cpu_millis(v) := m if {
	not endswith(v, "m")
	m := to_number(v) * 1000
}

memory_mi(v) := m if {
	endswith(v, "Gi")
	m := to_number(trim_suffix(v, "Gi")) * 1024
}

memory_mi(v) := m if {
	endswith(v, "Mi")
	m := to_number(trim_suffix(v, "Mi"))
}

deny contains msg if {
	input.kind == "Deployment"
	container := input.spec.template.spec.containers[_]
	limit := container.resources.limits.cpu
	cpu_millis(limit) > 1000
	msg := sprintf("container %s cpu limit %s exceeds the 1000m (1 core) cap", [container.name, limit])
}

deny contains msg if {
	input.kind == "Deployment"
	container := input.spec.template.spec.containers[_]
	limit := container.resources.limits.memory
	memory_mi(limit) > 1024
	msg := sprintf("container %s memory limit %s exceeds the 1Gi cap", [container.name, limit])
}

deny contains msg if {
	input.kind == "Deployment"
	input.spec.replicas > 3
	msg := sprintf("replicas %d exceeds the cap of 3 (this cluster's free-tier disk quota only fits 2 nodes)", [input.spec.replicas])
}
