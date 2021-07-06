import os

from celery import Celery
from celery.utils.log import get_task_logger

logger = get_task_logger(__name__)


# Set the default Django settings module for the 'celery' program.
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'sisyphe.settings')

app = Celery('sisyphe', broker=f"amqp://{ os.environ.get('AMQP_USER') }:{ os.environ.get('AMQP_PASSWORD') }@{ os.environ.get('AMQP_AUTHORITY') }:{ os.environ.get('AMQP_PORT') }/{ os.environ.get('AMQP_HOST') }")

# Using a string here means the worker doesn't have to serialize
# the configuration object to child processes.
# - namespace='CELERY' means all celery-related configuration keys
#   should have a `CELERY_` prefix.
app.config_from_object('django.conf:settings', namespace='CELERY')

# Load task modules from all registered Django apps.
app.autodiscover_tasks()

@app.task(bind=True)
def debug_task(self):
    logger.warning('yolo')
    logger.info('toto')
    print(f'Request: {self.request!r}')
