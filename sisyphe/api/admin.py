from django.contrib import admin
from .models import Campaign, Run, Process, EnvironmentVariable

admin.site.register(Campaign)
admin.site.register(Run)
admin.site.register(Process)
admin.site.register(EnvironmentVariable)