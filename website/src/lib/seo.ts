import { APP_STORE_URL } from '$lib/appstore';
import { APP_STORE_PRICE, GITHUB_REPO, GITHUB_RELEASES, LICENSE_URL } from '$lib/links';

export const SITE = {
  name: 'SSH Config Manager',
  legalName: 'SSH Config Manager',
  url: 'https://www.sshmanager.app',
  tagline: 'Open-source SSH configs, keys and tunnels for macOS and Linux',
  description: `A free, open-source, native app to edit ~/.ssh/config losslessly, manage SSH keys and known_hosts, and run in-process SSH tunnels (-L, -R, -D, ProxyJump) on macOS and Linux. Every feature is free. The Mac App Store build costs ${APP_STORE_PRICE.display} and supports development.`,
  ogImage: '/og.png',
  twitter: '@sshmanagerapp',
  keywords: [
    'open source SSH config manager',
    'SSH config editor macOS',
    'SSH config editor Linux',
    'ssh_config GUI',
    'SSH tunnel app',
    'manage SSH keys',
    'known_hosts manager',
    'ProxyJump GUI',
    'SSH port forwarding',
    'ssh-agent GUI'
  ]
} as const;

export function siteOrigin(): string {
  return SITE.url.replace(/\/$/, '');
}

export function absoluteUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) return path;
  return `${siteOrigin()}${path.startsWith('/') ? '' : '/'}${path}`;
}

type JsonLd = Record<string, unknown>;

const ORG_ID = `${SITE.url}/#organization`;
const WEBSITE_ID = `${SITE.url}/#website`;
const APP_ID = `${SITE.url}/#software`;

export function organizationLd(): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    '@id': ORG_ID,
    name: SITE.name,
    legalName: SITE.legalName,
    url: siteOrigin(),
    logo: absoluteUrl('/icon.svg'),
    description: SITE.description,
    sameAs: [GITHUB_REPO]
  };
}

export function websiteLd(): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'WebSite',
    '@id': WEBSITE_ID,
    name: SITE.name,
    url: siteOrigin(),
    publisher: { '@id': ORG_ID },
    inLanguage: 'en'
  };
}

export function softwareApplicationLd(): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    '@id': APP_ID,
    name: SITE.name,
    applicationCategory: 'DeveloperApplication',
    applicationSubCategory: 'SSH client',
    operatingSystem: 'macOS 15 or later, Linux',
    description: SITE.description,
    url: siteOrigin(),
    downloadUrl: GITHUB_RELEASES,
    installUrl: APP_STORE_URL,
    isAccessibleForFree: true,
    license: LICENSE_URL,
    codeRepository: GITHUB_REPO,
    sameAs: [APP_STORE_URL, GITHUB_REPO],
    screenshot: absoluteUrl(SITE.ogImage),
    featureList: [
      'Lossless ~/.ssh/config editor',
      'In-process SSH tunnels (-L, -R, -D)',
      'Multi-hop ProxyJump',
      'SSH key and ssh-agent management',
      'known_hosts manager with TOFU verification',
      'Git-style config version history'
    ],
    publisher: { '@id': ORG_ID },
    offers: [
      {
        '@type': 'Offer',
        price: '0',
        priceCurrency: 'USD',
        url: GITHUB_RELEASES,
        availability: 'https://schema.org/InStock'
      },
      {
        '@type': 'Offer',
        price: APP_STORE_PRICE.amount,
        priceCurrency: APP_STORE_PRICE.currency,
        url: APP_STORE_URL,
        availability: 'https://schema.org/InStock'
      }
    ]
  };
}

export function breadcrumbLd(crumbs: { name: string; path: string }[]): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: crumbs.map((c, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: c.name,
      item: absoluteUrl(c.path)
    }))
  };
}

export function faqLd(items: { question: string; answer: string }[]): JsonLd {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: items.map((it) => ({
      '@type': 'Question',
      name: it.question,
      acceptedAnswer: { '@type': 'Answer', text: it.answer }
    }))
  };
}
