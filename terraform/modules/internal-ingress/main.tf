# The Cloudflare Tunnel forwards every public hostname to this controller's
# ClusterIP Service. From there, nginx does host/path -> backend Service
# routing using the per-service Ingress resources each service's own Helm
# chart creates (base-service chart, ingressClassName: nginx-internal).
#
# controller.service.type is pinned to ClusterIP — the only Service type
# used anywhere in this tree. Nothing here is internet-facing or exposed via
# a cloud load balancer or a host-level port.
resource "helm_release" "ingress_nginx_internal" {
  name             = "ingress-nginx-internal"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 300

  values = [
    yamlencode({
      # fullnameOverride + controller.name="" makes the rendered Service name
      # exactly "ingress-nginx-internal" (the chart's fullname-controller
      # naming collapses to fullname when controller.name is empty), matching
      # the hostname the cloudflare-tunnel module's local config hardcodes.
      fullnameOverride = "ingress-nginx-internal"

      controller = {
        name = ""

        replicaCount = var.replica_count

        ingressClassResource = {
          name            = var.ingress_class_name
          default         = false
          controllerValue = "k8s.io/${var.ingress_class_name}"
        }
        ingressClass             = var.ingress_class_name
        watchIngressWithoutClass = false
        electionID               = "${var.ingress_class_name}-leader"

        service = {
          type = "ClusterIP"
        }

        resources = var.resources
      }
    })
  ]
}
