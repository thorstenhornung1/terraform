# Developer Onboarding Guide

Welcome! This guide will get you productive with our Docker Swarm cluster in 15 minutes.

## What You Need

1. SSH key added to manager nodes
2. This repo cloned locally
3. Basic Docker knowledge

## Step 1: Set Up SSH Access

Add to your `~/.ssh/config`:

```
Host swarm
    HostName 192.168.4.30
    User ansible
    IdentityFile ~/.ssh/id_ed25519

Host swarm-mgmt
    HostName 192.168.4.50
    User ansible
    IdentityFile ~/.ssh/id_ed25519
```

Test connection:

```bash
ssh swarm "docker node ls"
```

Expected output:

```
ID            HOSTNAME        STATUS    AVAILABILITY   MANAGER STATUS
xxxxx *       docker-app-1    Ready     Active         Reachable
xxxxx         docker-app-2    Ready     Active         Leader
xxxxx         docker-app-3    Ready     Active         Reachable
xxxxx         docker-infra-1  Ready     Active
xxxxx         docker-infra-2  Ready     Active
xxxxx         docker-infra-3  Ready     Active
xxxxx         swarmpit-mgmt   Ready     Active
```

## Step 2: Access Portainer

1. Open https://192.168.4.30:9443
2. Login with your credentials (ask admin if needed)
3. Click on "primary" environment
4. Explore: Stacks, Services, Containers, Nodes

## Step 3: Clone This Repo

```bash
git clone git@github.com:thorstenhornung1/swarm-stacks.git
cd swarm-stacks
```

## Step 4: Deploy Your First Stack

### Option A: Via Portainer (Recommended)

1. Portainer → Stacks → Add Stack
2. Name: `hello-world`
3. Paste this:

```yaml
version: '3.8'
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    deploy:
      replicas: 2
```

4. Click "Deploy the stack"
5. Access: http://192.168.4.30:8080

### Option B: Via CLI

```bash
# Copy stack file to manager
scp stacks/portainer/portainer-stack.yml swarm:~/

# Deploy
ssh swarm "docker stack deploy -c portainer-stack.yml mystack"

# Check
ssh swarm "docker stack services mystack"
```

## Step 5: Understand the Basics

### Key Commands

```bash
# List all stacks
docker stack ls

# List services in a stack
docker stack services <stack_name>

# List tasks (containers) for a service
docker service ps <service_name>

# View service logs
docker service logs <service_name>

# Scale a service
docker service scale <service_name>=3

# Remove a stack
docker stack rm <stack_name>
```

### Key Concepts

| Concept | Description |
|---------|-------------|
| Stack | Collection of services (like docker-compose) |
| Service | Definition of containers to run |
| Task | Single container instance of a service |
| Replica | Number of container instances |

## Step 6: Create Your Own Stack

1. Create directory: `stacks/myapp/`
2. Create `myapp-stack.yml`:

```yaml
version: '3.8'

services:
  app:
    image: your-image:tag
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
    networks:
      - app_network
    deploy:
      replicas: 2
      placement:
        constraints:
          - node.role == manager
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
      update_config:
        parallelism: 1
        delay: 10s
        failure_action: rollback
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3

networks:
  app_network:
    driver: overlay
```

3. Test deploy:

```bash
scp stacks/myapp/myapp-stack.yml swarm:~/
ssh swarm "docker stack deploy -c myapp-stack.yml myapp"
```

4. If it works, commit and push:

```bash
git add stacks/myapp/
git commit -m "Add myapp stack"
git push
```

## Common Tasks

### Update a running service

```bash
# Update image
docker service update --image nginx:1.25 mystack_web

# Or redeploy stack (preferred)
docker stack deploy -c mystack.yml mystack
```

### View logs

```bash
# All logs
docker service logs mystack_web

# Follow logs
docker service logs -f mystack_web

# Last 100 lines
docker service logs --tail 100 mystack_web
```

### Debug a failing service

```bash
# Check service status
docker service ps mystack_web --no-trunc

# Look for error messages
docker service logs mystack_web 2>&1 | grep -i error

# Inspect service
docker service inspect mystack_web
```

### Access a running container

```bash
# Find container ID
docker service ps mystack_web

# SSH to node where it runs, then exec
docker exec -it <container_id> sh
```

## Troubleshooting

### "No suitable node" error

Your placement constraints can't be satisfied.

```bash
# Check available nodes
docker node ls

# Check node labels
docker node inspect <node> --format '{{.Spec.Labels}}'
```

### Service stuck at 0/1 replicas

```bash
# Check why it's failing
docker service ps <service> --no-trunc

# Common causes:
# - Image not found (check registry access)
# - Port already in use
# - Resource limits too low
# - Placement constraints
```

### Can't pull image

```bash
# Check if registry is accessible
docker pull <image>

# For private registries, add credentials:
docker login <registry>
```

## Best Practices

1. **Always use specific image tags** - Never `:latest` in production
2. **Set resource limits** - Prevent runaway containers
3. **Use health checks** - Enable auto-recovery
4. **Use overlay networks** - Isolate service communication
5. **Pin stateful services** - Use placement constraints
6. **Test locally first** - Use docker-compose before swarm

## Getting Help

1. Check this repo's `docs/` folder
2. Ask in team chat
3. Open an issue in this repo

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for cluster details
- Read [NETWORKING.md](NETWORKING.md) for network topology
- Explore existing stacks in `stacks/` directory
