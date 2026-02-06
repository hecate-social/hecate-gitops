# User Applications

Deploy your applications here using Kustomize.

## Adding an Application

1. Create a directory for your app:
   ```
   mkdir my-app
   ```

2. Add your Kubernetes manifests:
   ```
   my-app/
   ├── deployment.yaml
   ├── service.yaml
   └── kustomization.yaml
   ```

3. Reference it in `kustomization.yaml`:
   ```yaml
   resources:
     - my-app/
   ```

4. Commit and push - FluxCD will deploy automatically.

## Example App Structure

```yaml
# my-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```
