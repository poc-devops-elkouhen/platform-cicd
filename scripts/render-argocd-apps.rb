#!/usr/bin/env ruby
# Génère les AppProject et l'ApplicationSet ArgoCD depuis l'inventaire unique
# argocd/apps.yaml. La sortie est committée dans argocd/managed/apps-appset.yaml
# (`make argocd-apps-render`) -- ArgoCD la synchronise en continu depuis Git via
# le root Application (argocd/root-app.yaml), elle n'est plus appliquée à la main.
require "yaml"

repo_root = File.expand_path("..", __dir__)
inventory_path = ENV.fetch("ARGOCD_APPS_FILE", File.join(repo_root, "argocd/apps.yaml"))

inventory = YAML.load_file(inventory_path)
apps = inventory.fetch("apps")

projects = apps.map do |app|
  name = app.fetch("name")
  argocd = app.fetch("argocd")

  {
    "apiVersion" => "argoproj.io/v1alpha1",
    "kind" => "AppProject",
    "metadata" => {
      "name" => argocd.fetch("project"),
      "namespace" => "argocd"
    },
    "spec" => {
      "sourceRepos" => argocd.fetch("sourceRepos"),
      "destinations" => argocd.fetch("destinations"),
      # Sans whitelist explicite, un AppProject bloque toute ressource cluster-scope,
      # y compris le Namespace que `syncOptions: [CreateNamespace=true]` doit créer.
      "clusterResourceWhitelist" => [
        { "group" => "", "kind" => "Namespace" }
      ]
    }
  }
end

elements = apps.flat_map do |app|
  name = app.fetch("name")
  manifests = app.fetch("manifests")
  repo_url = manifests.fetch("repoURL")
  path = manifests.fetch("path")

  app.fetch("environments").map do |env|
    env_name = env.fetch("name")
    {
      "app" => name,
      "project" => app.fetch("argocd").fetch("project"),
      "env" => env_name,
      "branch" => env.fetch("branch"),
      "namespace" => env.fetch("namespace"),
      "repoURL" => repo_url,
      "path" => path
    }
  end
end

applicationset = {
  "apiVersion" => "argoproj.io/v1alpha1",
  "kind" => "ApplicationSet",
  "metadata" => {
    "name" => "apps",
    "namespace" => "argocd"
  },
  "spec" => {
    "goTemplate" => true,
    "goTemplateOptions" => ["missingkey=error"],
    "generators" => [
      {
        "list" => {
          "elements" => elements
        }
      }
    ],
    "template" => {
      "metadata" => {
        "name" => "{{ .app }}-{{ .env }}",
        "finalizers" => ["resources-finalizer.argocd.argoproj.io"]
      },
      "spec" => {
        "project" => "{{ .project }}",
        "source" => {
          "repoURL" => "{{ .repoURL }}",
          "targetRevision" => "{{ .branch }}",
          "path" => "{{ .path }}"
        },
        "destination" => {
          "server" => "https://kubernetes.default.svc",
          "namespace" => "{{ .namespace }}"
        },
        "syncPolicy" => {
          "automated" => {
            "prune" => true,
            "selfHeal" => true
          },
          "syncOptions" => ["CreateNamespace=true"]
        }
      }
    }
  }
}

puts "# Généré par scripts/render-argocd-apps.rb depuis argocd/apps.yaml -- ne pas éditer à la main."
(projects + [applicationset]).each_with_index do |document, index|
  puts "---" unless index.zero?
  puts YAML.dump(document).sub(/\A---\s*\n/, "")
end
