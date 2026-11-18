import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { appStoreAPI, appId } from './app-store-api.mjs';

export { appId };
export const buildId = 'f8555767-8496-46df-988f-33c4f80fdbe6';
export const version = '1.0.4';
export const releaseNotes = "Choose and confirm where your data goes before starting sync. You can use hosted storage or connect your own server.\nChoose the Apple Health data types you want to sync during setup and update your selection in Settings.\nStop an active sync, clear pending uploads, or switch to Manual Only from the app.";
export const reviewNotes = "On a clean install, tap Continue, select Hosted HealthSync storage, then tap Create Hosted Storage. When storage is ready, tap Continue, choose Health data types, and tap Allow Health Access to open the iOS permission prompt. The dashboard then offers Sync Last 24 Hours. The app reports when there are no matching samples. Hosted setup requires an internet connection and no reviewer credentials. The My own backend option is for users who run their own server. In Settings, changing the storage destination requires confirmation. HealthSync requests read access to Apple Health.";
const relation = (type, id) => ({ data: { type, id } });

export async function preparePatch(api) {
    const app = (await api(`apps/${appId}`)).data;
    assert.equal(app.attributes.bundleId, 'com.megabyte0x.HealthSync', 'Unexpected app');
    const build = await api(`builds/${buildId}`, { query: { include: 'app,preReleaseVersion' } });
    assert.equal(build.data.relationships.app.data.id, appId, 'Wrong build owner');
    assert.equal(build.data.attributes.version, '36', 'Unexpected build');
    assert.equal(build.data.attributes.processingState, 'VALID', 'Build not processed');
    assert.equal(build.data.attributes.expired, false, 'Build expired');
    const prerelease = build.included.find(x => x.type === 'preReleaseVersions' && x.id === build.data.relationships.preReleaseVersion.data.id);
    assert.equal(prerelease?.attributes.version, version, 'Unexpected app version');
    assert.equal(prerelease?.attributes.platform, 'IOS', 'Unexpected platform');
    const versions = await api(`apps/${appId}/appStoreVersions`, { query: { limit: '200', 'filter[platform]': 'IOS' } });
    assert(!versions.links?.next, 'Version list requires pagination');
    const prior = versions.data.find(x => x.attributes.versionString === '1.0.3');
    assert.equal(prior?.attributes.appStoreState, 'READY_FOR_SALE', 'Expected released baseline');
    assert.equal(prior.attributes.releaseType, 'AFTER_APPROVAL', 'Unexpected release policy');
    let target = versions.data.find(x => x.attributes.versionString === version);
    if (!target) target = (await api('appStoreVersions', { method: 'POST', data: {
        type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: version, copyright: prior.attributes.copyright, releaseType: prior.attributes.releaseType },
        relationships: { app: relation('apps', appId) },
    } })).data;
    assert.equal(target.attributes.appStoreState, 'PREPARE_FOR_SUBMISSION', 'Target is not an editable draft');
    assert.equal(target.attributes.releaseType, prior.attributes.releaseType, 'Draft has a different release policy');
    const details = await api(`appStoreVersions/${target.id}`, { query: { include: 'build,appStoreReviewDetail' } });
    const selectedBuild = details.data.relationships.build.data?.id;
    assert(!selectedBuild || selectedBuild === buildId, 'Draft has another build selected');
    const localizations = await api(`appStoreVersions/${target.id}/appStoreVersionLocalizations`, { query: { limit: '200' } });
    assert(!localizations.links?.next && localizations.data.length > 0, 'Expected inherited localizations');
    assert(localizations.data.every(x => /^en(-|$)/.test(x.attributes.locale)), 'Release notes need additional translations');
    const review = details.included?.find(x => x.type === 'appStoreReviewDetails');
    assert(review && ['contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail'].every(k => review.attributes[k]), 'Review information incomplete');
    assert.equal(review.attributes.demoAccountRequired, false, 'Unexpected demo account requirement');
    if (review.attributes.notes !== reviewNotes) await api(`appStoreReviewDetails/${review.id}`, { method: 'PATCH', data: {
        type: 'appStoreReviewDetails', id: review.id, attributes: { notes: reviewNotes },
    } });
    for (const locale of localizations.data) {
        await api(`appStoreVersionLocalizations/${locale.id}`, { method: 'PATCH', data: {
            type: 'appStoreVersionLocalizations', id: locale.id, attributes: { whatsNew: releaseNotes },
        } });
    }
    if (!selectedBuild) await api(`appStoreVersions/${target.id}`, { method: 'PATCH', data: {
        type: 'appStoreVersions', id: target.id, relationships: { build: relation('builds', buildId) },
    } });
    return { version, build: '36', versionId: target.id, releaseType: target.attributes.releaseType, localizations: localizations.data.map(x => x.attributes.locale), state: target.attributes.appStoreState };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    assert.equal(process.env.APP_VERSION, version, 'This preparation is only for the verified 1.0.4 candidate');
    console.log(JSON.stringify(await preparePatch(appStoreAPI()), null, 2));
}
