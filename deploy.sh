# environment variables
[ ! -f .env ] || export $(grep -v '^#' .env | xargs)
WANDB_HOST_IP=$(hostname -I | cut -d' ' -f1)
export WANDB_BASE_URL=http://$WANDB_HOST_IP:$WANDB_PORT
echo $WANDB_BASE_URL

# start from default server
# wandb server start --port ${WANDB_PORT}

# -------------------------------------------------------------------
# clean install
if [ "$CLEAN_INSTALL" = true ]
then
    echo "🧹 Clean Install ..."
    echo "rm wandb volume" && docker volume rm wandb
    echo "rm prefix:$WANDB_PREFIX" && sudo rm -rf $WANDB_PREFIX
    echo "rm ~/.config/wandb" && sudo rm -rf ~/.config/wandb/
    echo "rm ~/.wandb" && sudo rm -rf ~/.wandb
    echo "rm ~/.netrc" && sudo rm ~/.netrc

fi

# -------------------------------------------------------------------
# create bind mount
sudo mkdir -p $WANDB_PREFIX
sudo chown 999:999 $WANDB_PREFIX


# -------------------------------------------------------------------
# docker compose up
echo "🚀 Deploying through Docker Compose ..."
docker compose -f docker/docker-compose.yml up -d
# docker run -d -v ${WANDB_PREFIX}:/vol -p ${WANDB_PORT}:8080 --name wandb wandb/local:latest
# wandb login --relogin --host=${WANDB_BASE_URL}

