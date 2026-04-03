# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KubeVela is a modern application delivery platform built on the [Open Application Model (OAM)](https://oam.dev/). It provides a "render, orchestrate, deploy" workflow for deploying applications across hybrid, multi-cloud environments. The platform uses CUE for templating and configuration extension.

## Build Commands

```bash
# Build CLI binaries (vela and kubectl-vela)
make build

# Run unit tests (core + cli gen)
make test

# Run unit tests only for core packages
make unit-test-core

# Run linter (golangci-lint)
make lint

# Run go fmt, imports formatter, and CUE fmt
make fmt

# Run go vet
make vet

# Run staticcheck
make staticcheck

# Generate CRDs and manifests
make manifests

# Build core manager binary
make manager

# Run the core controller locally (requires kubeconfig)
make run

# Run E2E tests (requires cluster)
make e2e-test

# Run specific E2E application tests locally with k3d
make e2e-application-test-local
```

### Running a Single Test

```bash
# Using standard go test
go test -v ./pkg/controller/core.oam.dev/v1beta1/application/... -run TestSingleTestName

# With kubebuilder assets (required for some controller tests)
KUBEBUILDER_ASSETS="$(./bin/setup-envtest use 1.31.0 -p path)" go test ./pkg/...
```

## Architecture

### Core Components

- **Controller** (`pkg/controller/core.oam.dev/`): Kubernetes controllers for Application, ComponentDefinition, TraitDefinition, PolicyDefinition, WorkflowStepDefinition
- **Workflow** (`pkg/workflow/`): Workflow engine powered by `github.com/kubevela/workflow` package. Handles step execution, providers, and operations
- **Definition System** (`pkg/definition/`): CUE-based definition loading and processing. Uses `pkg/definition/defkit/` for CUE code generation
- **CUE Processing** (`pkg/cue/`): CUE template conversion, parsing, and execution
- **OAM Core** (`pkg/oam/`): OAM utility functions and types

### API Types

- **APIs** (`apis/core.oam.dev/`): Kubernetes API types for Application, ComponentDefinition, TraitDefinition, etc.
- **References** (`references/`): CLI documentation and command definitions

### Application Model

Applications are defined via CUE templates in `vela-templates/definitions/`. The controller reconciles Application resources by:
1. Parsing component definitions and their CUE templates
2. Processing traits and policies
3. Executing the workflow (using kubevela/workflow)
4. Rendering and applying final Kubernetes resources

### Key Packages

| Package | Purpose |
|---------|---------|
| `pkg/controller/core.oam.dev/v1beta1/application/` | Application reconciliation controller |
| `pkg/workflow/providers/` | Built-in workflow step providers (CUE, OAM, multicluster, terraform) |
| `pkg/definition/` | Definition loading and CUE template processing |
| `pkg/cue/` | CUE template conversion and execution |
| `pkg/oam/` | OAM utilities, labels, and helpers |
| `pkg/resourcekeeper/` | Resource lifecycle management |
| `pkg/resourcetracker/` | Application revision resource tracking |
| `pkg/multicluster/` | Multi-cluster communication and federation |

### CLI Structure

- **Core Command** (`cmd/core/`): The vela-core controller binary entrypoint
- **CLI** (`references/cmd/cli/`): The `vela` CLI binary
- **Plugin** (`cmd/plugin/`): The `kubectl-vela` kubectl plugin

## Code Generation

- **CUE Gen** (`hack/cuegen/`): Generates Go types from CUE definitions
- **Doc Gen** (`references/docgen/`): Generates CLI documentation from definitions
- CRDs are generated via `make manifests` using controller-gen

## Dependencies

Key external dependencies managed in `go.mod`:
- `cuelang.org/go` - CUE language implementation
- `github.com/kubevela/workflow` - Workflow engine
- `github.com/kubevela/pkg` - Shared CRD types
- `github.com/oam-dev/cluster-gateway` - Multi-cluster federation
- `github.com/crossplane/crossplane-runtime` - Kubernetes extensions

## Development Notes

- The project uses Go 1.23.8
- CUE formatting is required for vela-templates: `make fmt`
- Generated code should be checked with `make check-diff` before committing
- The E2E tests require a running Kubernetes cluster (k3d supported via `make e2e-test-local`)
