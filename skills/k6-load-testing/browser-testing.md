# Browser Testing (k6 Browser)

## Browser Testing (k6 Browser)

```javascript
import { browser } from 'k6/browser';

export const options = {
  scenarios: {
    browser_test: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      browser: {
        type: 'chromium',
      },
    },
  },
};

export default async function () {
  const page = await browser.newPage();
  
  try {
    await page.goto('https://example.com');
    
    const title = await page.title();
    console.log(`Page title: ${title}`);
    
    // Click and interact
    await page.click('button[data-testid="submit"]');
    
    // Wait for response
    await page.waitForSelector('.success-message');
    
  } finally {
    await page.close();
  }
}
```

Install browser support: `k6 install chromium`

---
