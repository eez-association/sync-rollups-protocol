# Vercel Deployment

**Live URL:** https://visualizator-woad.vercel.app

## Redeploy after changes

```bash
cd visualizator && vercel --yes --prod
```

## Other commands

```bash
# Preview deploy (non-production)
cd visualizator && vercel

# Check deploy logs
vercel inspect visualizator-woad.vercel.app --logs

# List deployments
vercel ls visualizator

# Set custom domain
vercel domains add your-domain.com
```
