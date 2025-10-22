# Building Custom Benchmark Images

This directory contains the resources needed to build custom GuideLLM benchmark container images for OpenShift.

## Files

- **Dockerfile** - Container image definition
- **buildconfig.yaml** - OpenShift BuildConfig resource
- **imagestream.yaml** - OpenShift ImageStream resource

## Quick Start

### Using OpenShift BuildConfig

```bash
# Apply the resources
oc apply -f imagestream.yaml -n keda
oc apply -f buildconfig.yaml -n keda

# Start a build
oc start-build guidellm-runner -n keda

# Watch the build progress
oc logs -f bc/guidellm-runner -n keda

# Verify the built image
oc get imagestream guidellm-runner -n keda
oc describe imagestream guidellm-runner -n keda
```

### Using Docker/Podman

```bash
# Build the image
docker build -f Dockerfile -t guidellm-runner:latest .

# Or with Podman
podman build -f Dockerfile -t guidellm-runner:latest .

# Tag and push to your registry
docker tag guidellm-runner:latest your-registry.com/guidellm-runner:latest
docker push your-registry.com/guidellm-runner:latest
```

## Image Contents

The image includes:
- Python 3.11
- GuideLLM benchmark tool (experimental branch with additional rate types)
- oc CLI tool
- Monitoring scripts
- Telegram notification support (optional)

## Customization

To customize the image:

1. Edit the `Dockerfile` to add/remove packages or change versions
2. If using BuildConfig, update the `buildconfig.yaml` if needed
3. Rebuild the image using the commands above
4. Update your Helm values to use the new image:

```yaml
benchmark:
  image:
    repository: your-registry.com/guidellm-runner
    tag: your-custom-tag
```

## Troubleshooting

### Build Fails

Check build logs:
```bash
oc logs -f bc/guidellm-runner -n keda
```

Common issues:
- Network connectivity for downloading packages
- Insufficient resources in the build pod
- Git repository access issues

### Image Not Available

Verify the ImageStream:
```bash
oc describe imagestream guidellm-runner -n keda
```

Check that the build completed successfully:
```bash
oc get builds -n keda | grep guidellm-runner
```
