### Installing in OpenShift

Create the secret as described in the kubernetes documentation

4odify the `configmap.yaml` for your configuration and apply.

```
oc apply -f configmap.yaml
```

Apply the role, rolebinding, service, deployment and ServiceMonitor

```
oc apply -f rolebinding.yaml
oc apply -f service.yaml
oc apply -f deployment.yaml
oc apply -f servicemonitor.yaml
```



