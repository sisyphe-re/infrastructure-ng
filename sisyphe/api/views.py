from django.shortcuts import render
from django.template import loader
from django.http import HttpResponse
from .models import Campaign, Run

def index(request):
    all_campaigns = Campaign.objects.order_by('name')[:5]
    template = loader.get_template('api/index.html')
    context = {
        'campaigns': all_campaigns
    }
    return HttpResponse(template.render(context, request))

def campaign_detail(request, campaign_id):
    campaign = Campaign.objects.get(pk=campaign_id)
    runs = campaign.run_set.all()
    template = loader.get_template('api/campaign.html')
    context = {
        'campaign': campaign,
        'runs': runs
    }
    return HttpResponse(template.render(context, request))

def run_detail(request, run_id):
    run = Run.objects.get(pk=run_id)
    template = loader.get_template('api/run.html')
    context = {
        'run': run
    }
    return HttpResponse(template.render(context, request))
