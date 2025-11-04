# Build and Push Custom Guidellm Image using OpenShift Builds

## Building the Image

1.  **Create the ImageStream and BuildConfig:**

    The `imagestream.yaml` file defines a place to store your built images, and the `buildconfig.yaml` defines how to build the image from the source code in this directory.

    Apply them to your project:
    ```bash
    oc apply -f imagestream.yaml
    oc apply -f buildconfig.yaml
    ```

2.  **Start the Build:**

    From within this `build` directory, run the following command. This will upload the contents of the current directory (the "build context") to OpenShift and start the build process.

    The `-w` flag waits for the build to complete and streams the logs to your terminal.

    ```bash
    oc start-build guidellm-custom-build --from-dir=. -w
    ```

    If the build is successful, a new image will be pushed to the `guidellm-custom` image stream.

## Using the Image

You can now use the image `image-registry.openshift-image-registry.svc:5000/<project-name>/guidellm-custom:latest` in your OpenShift deployments. The internal service URL is the most reliable way to reference the image from within the cluster.
