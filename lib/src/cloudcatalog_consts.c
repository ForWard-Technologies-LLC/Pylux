// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Region groups + store-locale fallback chain. Ported from KamajiConsts
// (gui/include/cloudstreaming/pskamajisession.h) and canonicalStoreLocale /
// buildStoreLocaleFallbackChain (gui/src/cloudcatalogbackend.cpp).

#include "cloudcatalog_internal.h"

#include <chiaki/cloudcatalog.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static bool is_americas_classics_region(const char *cc)
{
	if(!cc || !*cc)
		return false;
	static const char *const americas[] = {
		"US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "EC", "BO",
		"PY", "UY", "CR", "GT", "HN", "NI", "PA", "SV", "DO", NULL
	};
	char up[8] = { 0 };
	for(size_t i = 0; i < sizeof(up) - 1 && cc[i]; i++)
		up[i] = (char)toupper((unsigned char)cc[i]);
	for(size_t i = 0; americas[i]; i++)
		if(strcmp(up, americas[i]) == 0)
			return true;
	return false;
}

const char *cc_classics_store_country(const char *account_country)
{
	return is_americas_classics_region(account_country) ? "US" : "GB";
}

const char *cc_apollo_root_container_id(const char *account_country)
{
	return is_americas_classics_region(account_country)
		? "STORE-MSF192018-APOLLOROOT"
		: "STORE-MSF192014-APOLLOROOT";
}

// Canonicalize "language-COUNTRY" to lowercase-lang / uppercase-country.
// Writes into out (size >= 16). Defaults to "en-US".
static void canonical_store_locale(const char *raw, char *out, size_t out_sz)
{
	char lang[8] = { 0 };
	char country[8] = { 0 };

	// trim leading space
	const char *p = raw ? raw : "";
	while(*p && isspace((unsigned char)*p))
		p++;
	if(!*p)
	{
		snprintf(out, out_sz, "en-US");
		return;
	}

	const char *dash = strchr(p, '-');
	size_t lang_len = dash ? (size_t)(dash - p) : strlen(p);
	if(lang_len >= sizeof(lang))
		lang_len = sizeof(lang) - 1;
	for(size_t i = 0; i < lang_len; i++)
		lang[i] = (char)tolower((unsigned char)p[i]);

	if(dash)
	{
		const char *cp = dash + 1;
		size_t clen = strlen(cp);
		// trim trailing whitespace
		while(clen > 0 && isspace((unsigned char)cp[clen - 1]))
			clen--;
		if(clen >= sizeof(country))
			clen = sizeof(country) - 1;
		for(size_t i = 0; i < clen; i++)
			country[i] = (char)toupper((unsigned char)cp[i]);
	}

	if(!lang[0])
		snprintf(lang, sizeof(lang), "en");
	if(!country[0])
		snprintf(country, sizeof(country), "US");
	snprintf(out, out_sz, "%s-%s", lang, country);
}

size_t cc_build_store_locale_chain(const char *stored, char **out, size_t max)
{
	if(!out || max == 0)
		return 0;

	char canonical[16];
	canonical_store_locale(stored, canonical, sizeof(canonical));

	const char *dash = strchr(canonical, '-');
	const char *country = dash ? dash + 1 : "US";

	char en_country[16];
	snprintf(en_country, sizeof(en_country), "en-%s", country);

	const char *candidates[3] = { canonical, en_country, "en-US" };
	size_t count = 0;
	for(size_t i = 0; i < 3 && count < max; i++)
	{
		bool dup = false;
		for(size_t j = 0; j < count; j++)
			if(strcmp(out[j], candidates[i]) == 0)
			{
				dup = true;
				break;
			}
		if(!dup)
			out[count++] = strdup(candidates[i]);
	}
	return count;
}

// ---------------------------------------------------------------------------
// Cloud streaming language picker locales (display order). Platforms render
// localized names; datacenter selection is independent of language choice.
// ---------------------------------------------------------------------------

// Distinct picker locales, in display order. Platforms render localized names.
static const char *const kSupportedLocales[] = {
	"en-US", "en-GB", "de-DE", "fr-FR", "fi-FI",
	"it-IT", "es-ES", "nl-NL", "pt-BR", "ja-JP", "ko-KR",
};

void chiaki_cloud_gaikai_language(const char *locale, char *out, size_t out_sz)
{
	if(!out || out_sz == 0)
		return;
	out[0] = 0;
	const char *p = locale ? locale : "";
	while(*p && isspace((unsigned char)*p))
		p++;
	size_t i = 0;
	for(; p[i] && p[i] != '-' && p[i] != '_' && i < out_sz - 1; i++)
		out[i] = (char)tolower((unsigned char)p[i]);
	out[i] = 0;
	if(!out[0])
		snprintf(out, out_sz, "en");
}

size_t chiaki_cloud_supported_locale_count(void)
{
	return sizeof(kSupportedLocales) / sizeof(kSupportedLocales[0]);
}

const char *chiaki_cloud_supported_locale(size_t idx)
{
	return idx < chiaki_cloud_supported_locale_count() ? kSupportedLocales[idx] : "";
}
