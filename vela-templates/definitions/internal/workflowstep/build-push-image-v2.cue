import (
	"vela/builtin"
	"vela/kube"
	"vela/util"
	"strings"
)

"build-push-image-v2": {
	alias: ""
	attributes: {}
	description: "Build and push image from GitLab SSH repo using a remote Docker daemon."
	annotations: {
		"category": "CI Integration"
	}
	labels: {}
	type: "workflow-step"
}

template: {
	_podName: "\(context.name)-\(context.stepSessionID)-builder"

	_sshSecretName: "\(context.name)-\(context.stepSessionID)-git-ssh"

	_fullImage: "\(parameter.registry)/\(parameter.repo)/\(parameter.imageName):\(parameter.imageTag)"

	_buildArgsJoined: {
		if parameter.buildArgs != _|_ {
			value: strings.Join(parameter.buildArgs, ",")
		}
		if parameter.buildArgs == _|_ {
			value: ""
		}
	}

	// Create Secret from inline sshKey first; builder references $returns so execution order is preserved.
	sshSecretApply: kube.#Apply & {
		$params: {
			value: {
				apiVersion: "v1"
				kind:       "Secret"
				metadata: {
					name:      _sshSecretName
					namespace: context.namespace
				}
				type: "Opaque"
				stringData: {
					"ssh-privatekey": parameter.sshKey
				}
			}
		}
	}

	builder: kube.#Apply & {
		$params: {
			value: {
				apiVersion: "v1"
				kind:       "Pod"
				metadata: {
					name:      _podName
					namespace: context.namespace
					annotations: {
						"vela.dev/depends-on-ssh-secret": sshSecretApply.$returns.value.metadata.name
					}
				}
				spec: {
					containers: [
						{
							name:  "builder"
							image: parameter.builderImage
							env: [
								{name: "GIT_URL", value:      parameter.gitURL},
								{name: "GIT_BRANCH", value:   parameter.gitBranch},
								{name: "CODE_TYPE", value:    parameter.codeType},
								{name: "DOCKER_HOST", value:  parameter.dockerHost},
								{name: "REGISTRY", value:     parameter.registry},
								{name: "REPO", value:         parameter.repo},
								{name: "IMAGE_NAME", value:   parameter.imageName},
								{name: "IMAGE_TAG", value:    parameter.imageTag},
								{name: "BUILD_ARGS", value:   _buildArgsJoined.value},
								if parameter.dockerfile != _|_ {
									{name: "DOCKERFILE", value: parameter.dockerfile}
								},
							]
							volumeMounts: [
								{
									name:      "ssh-key"
									mountPath: "/root/.ssh/id_rsa"
									subPath:   "ssh-privatekey"
									readOnly:  true
								},
							]
						},
					]
					volumes: [
						{
							name: "ssh-key"
							secret: {
								secretName:  _sshSecretName
								defaultMode: 384
								items: [
									{
										key:  "ssh-privatekey"
										path: "ssh-privatekey"
									},
								]
							}
						},
					]
					restartPolicy: "Never"
				}
			}
		}
	}

	log: util.#Log & {
		$params: {
			source: {
				resources: [{
					name:      _podName
					namespace: context.namespace
				}]
			}
		}
	}

	read: kube.#Read & {
		$params: {
			value: {
				apiVersion: "v1"
				kind:       "Pod"
				metadata: {
					name:      _podName
					namespace: context.namespace
				}
			}
		}
	}

	wait: builtin.#ConditionalWait & {
		if read.$returns.value.status != _|_ {
			$params: continue: read.$returns.value.status.phase == "Succeeded"
		}
	}

	parameter: {
		// +usage=Specify the GitLab SSH URL, e.g. ssh://git@gitlab.example.com/group/repo.git
		gitURL: string
		// +usage=Specify the git branch to build from
		gitBranch: *"main" | string
		// +usage=Specify the code type for auto-generating Dockerfile when not provided in repo
		codeType: "python3.12-pip" | "java21-maven" | "node-yarn" | "node-npm"
		// +usage=Specify the remote Docker daemon address
		dockerHost: *"tcp://192.168.1.1:2375" | string
		// +usage=Specify the image registry address
		registry: *"harbor.dev.example.com" | string
		// +usage=Specify the image repository path, e.g. "team" or "library"
		repo: string
		// +usage=Specify the image name
		imageName: string
		// +usage=Specify the image tag
		imageTag: *"latest" | string
		// +usage=Specify a custom Dockerfile path relative to the repo root; if empty, a Dockerfile will be auto-generated based on codeType
		dockerfile?: string
		// +usage=Specify extra docker build args, e.g. ["KEY1=VAL1", "KEY2=VAL2"]
		buildArgs?: [...string]
		// +usage=SSH private key PEM for GitLab (ssh://). A Secret is created in the application namespace before the builder Pod runs; avoid committing this value to git.
		sshKey: string
		// +usage=Specify the builder image that contains docker CLI, git, and entrypoint.sh
		builderImage: *"harbor.dev.example.com/infra/vela-builder:latest" | string
	}
}
