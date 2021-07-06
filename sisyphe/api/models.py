from django.db import models
from sisyphe.celery import app

class Campaign(models.Model):
    name = models.CharField(max_length=100)
    source = models.URLField()
    duration = models.IntegerField(default=600)

    def __str__(self):
        return f"{self.name} -> {self.source}"

class Run(models.Model):
    start = models.DateTimeField(auto_now_add=True)
    end = models.DateTimeField(null=True, blank=True)
    campaign = models.ForeignKey(Campaign, on_delete=models.CASCADE)
    uuid = models.CharField(max_length=100, default='')

class Process(models.Model):
    run = models.ForeignKey(Run, on_delete=models.CASCADE)
    pid = models.IntegerField()
    running = models.BooleanField(default=True)
    sshPort = models.IntegerField()

class EnvironmentVariable(models.Model):
    campaign = models.ManyToManyField(Campaign)
    key = models.TextField()
    value = models.TextField()

    def __str__(self):
        return f"{self.key} -> {self.value}"
