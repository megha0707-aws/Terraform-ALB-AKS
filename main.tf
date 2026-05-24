############################################
# RESOURCE GROUP
############################################

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

############################################
# NETWORK
############################################

resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = var.aks_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.aks_subnet_prefix
}

resource "azurerm_subnet" "alb_subnet" {
  name                 = var.alb_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.alb_subnet_prefix

  delegation {
    name = "albdelegation"

    service_delegation {
      name = "Microsoft.ServiceNetworking/trafficControllers"
    }
  }
}

############################################
# AKS
############################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "system"
    node_count     = var.node_count
    vm_size        = var.vm_size
    vnet_subnet_id = azurerm_subnet.aks_subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }
}

############################################
# ALB
############################################

resource "azurerm_application_load_balancer" "alb" {
  name                = var.alb_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_application_load_balancer_frontend" "frontend" {
  name                          = "public-frontend"
  application_load_balancer_id  = azurerm_application_load_balancer.alb.id
}

resource "azurerm_application_load_balancer_subnet_association" "assoc" {
  name                          = "aks-association"
  application_load_balancer_id  = azurerm_application_load_balancer.alb.id
  subnet_id                     = azurerm_subnet.alb_subnet.id
}

############################################
# RBAC
############################################

resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "network" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "appgw" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}


############################################
# ALB CONTROLLER
############################################

resource "helm_release" "alb_controller" {
  name             = "alb-controller"
  namespace        = "azure-alb-system"
  create_namespace = true

  repository = "oci://mcr.microsoft.com/application-lb/charts"
  chart      = "alb-controller"

  values = [
    yamlencode({
      albController = {
        podIdentity = {
          clientID = azurerm_kubernetes_cluster.aks.kubelet_identity[0].client_id
        }
      }
    })
  ]

  depends_on = [
    azurerm_role_assignment.reader,
    azurerm_role_assignment.network,
    azurerm_role_assignment.appgw
  ]
}

############################################
# NGINX DEPLOYMENT
############################################

resource "kubernetes_deployment" "nginx" {
  metadata {
    name = "sample-web"

    labels = {
      app = "sample-web"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "sample-web"
      }
    }

    template {
      metadata {
        labels = {
          app = "sample-web"
        }
      }

      spec {
        container {
          image = "nginx"
          name  = "nginx"

          port {
            container_port = 80
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller]
}

############################################
# SERVICE
############################################

resource "kubernetes_service" "nginx" {
  metadata {
    name = "sample-web-service"
  }

  spec {
    selector = {
      app = "sample-web"
    }

    port {
      port        = 80
      target_port = 80
    }
  }
}
############################################
# GATEWAY
############################################

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"

    metadata = {
      name      = "sample-gateway"
      namespace = "default"

      annotations = {
        "alb.networking.azure.io/alb-id" = azurerm_application_load_balancer.alb.id
        "alb.networking.azure.io/frontend-name" = "public-frontend"
      }
    }

    spec = {
      gatewayClassName = "azure-alb-external"

      listeners = [
        {
          name     = "http"
          port     = 80
          protocol = "HTTP"

          allowedRoutes = {
            namespaces = {
              from = "Same"
            }
          }
        }
      ]
    }
  }

  depends_on = [
    helm_release.alb_controller
  ]
}

############################################
# HTTP ROUTE
############################################

resource "kubernetes_manifest" "route" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"

    metadata = {
      name      = "sample-route"
      namespace = "default"
    }

    spec = {
      parentRefs = [
        {
          name = "sample-gateway"
        }
      ]

      rules = [
        {
          matches = [
            {
              path = {
                type  = "PathPrefix"
                value = "/"
              }
            }
          ]

          backendRefs = [
            {
              name = "sample-web-service"
              port = 80
            }
          ]
        }
      ]
    }
  }

  depends_on = [
    kubernetes_service.nginx
  ]
}