from django.contrib import admin
from .models import Campaign, Run, EnvironmentVariable

admin.site.register(Campaign)
admin.site.register(Run)
admin.site.register(EnvironmentVariable)