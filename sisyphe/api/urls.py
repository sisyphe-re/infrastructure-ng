from django.urls import path

from . import views

urlpatterns = [
    path('', views.index, name='index'),
    path('campaign/<int:campaign_id>/', views.campaign_detail, name='campaign_detail'),
    path('run/<int:run_id>/', views.run_detail, name='run_detail'),
]
