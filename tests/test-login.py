import wandb
wandb.init(project="my-awesome-project")
wandb.log({'accuracy': 0.2, 'loss': 0.1})
wandb.config.dropout = 0.2
