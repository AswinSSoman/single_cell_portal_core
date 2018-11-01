/**
 * @fileoverview Functions and event handlers for igv.js genome browser.
 * Provides a way to view nucleotide sequencing reads in genomic context.
 */

// Persists 'Genome' tab and IGV embed across view states.
// Ensures that IGV doesn't disappear when user clicks 'Browse in genome' in
// default view, then searches a gene.
window.hasDisplayedIgv = false;

window.bamsToViewInIgv = [];
window.selectedBams = {};

window.genomeAssemblyInView = '';

/**
 * Upon clicking 'Browse in genome', show selected BAM in igv.js in Genome tab.
 */
$(document).on('click', '.bam-browse-genome', function(e) {
  var selectedBam, thisBam, url, i;

  selectedBam = $(this).attr('data-filename');

  // bamAndBaiFiles assigned in _genome.html.erb
  for (i = 0; i < bamAndBaiFiles.length; i++) {
    url = bamAndBaiFiles[i].url;
    if (typeof url === 'undefined' || url === '?alt=media') {
      // Accounts for "Awaiting remote file"
      continue;
    }
    thisBam = url.split('\/o/')[1].split('?')[0];
    if (thisBam === selectedBam && selectedBam in selectedBams === false) {
      bamsToViewInIgv.push(bamAndBaiFiles[i]);
    }
    selectedBams[thisBam] = 1;
  }

  $('#study-visualize-nav > a').click();
  $('#genome-tab-nav > a').click();
});

$(document).on('click', '#genome-tab-nav', function (e) {
  window.location.hash = '#genome-tab';

  // Go to Google sign-in page, redirect to this view after authenticating.
  if (accessToken === null) {
    ga('send', 'event', 'genome', 'sign_in_start');
    localStorage.setItem('signed-in-via-genome-tab', true);
    window.location = '/single_cell/users/auth/google_oauth2';
  }
});

/**
 * Get tracks for selected BAM files, to show sequencing reads
 */
function getBamTracks() {
  var bam, bamTrack, bamTracks, i, bamFileName;

  bamTracks = [];

  for (i = 0; i < bamsToViewInIgv.length; i++) {
    bam = bamsToViewInIgv[i];

    // Extracts BAM file name from its GCS API URL
    bamFileName = bam.url.split('/o/')[1].split('?')[0];

    bamTrack = {
      url: bam.url,
      indexURL: bam.indexUrl,
      oauthToken: accessToken,
      label: bamFileName
    };
    bamTracks.push(bamTrack);
  }

  return bamTracks;
}

/**
 * Gets the track of genes and transcripts from the genome's BED file
 */
function getGenesTrack(genome, genesTrackName) {
  var gtfFile, genesTrack;

  // gtfFiles assigned in _genome.html.erb
  gtfFile = gtfFiles[genome].genome_annotations;

  genesTrack = {
    name: genesTrackName,
    url: gtfFile.url + '?alt=media',
    indexURL: gtfFile.indexUrl + '?alt=media',
    type: 'annotation',
    format: 'gtf',
    sourceType: 'file',
    height: 102,
    order: 0,
    visibilityWindow: 300000000,
    displayMode: 'EXPANDED',
    oauthToken: accessToken // Assigned in _genome.html.erb
  };

  return genesTrack;
}

// Monkey patch getKnownGenome to remove baked-in genes track.
// We use a different gene annotation source, in a different track order,
// so removing this default gives our genome browser instance a more
// polished feel.
var originalGetKnownGenomes = igv.GenomeUtils.getKnownGenomes;
igv.GenomeUtils.getKnownGenomes = function () {
  return originalGetKnownGenomes.apply(this).then(function(reference) {
    var key,
        newRef = {};
    newRef['GRCm38'] = reference['mm10']; // Fix name
    for (key in reference) {
      delete reference[key].tracks;
      newRef[key] = reference[key];
    }
    return newRef;
  })
};

function igvIsDisplayed() {
  return $('#igvRootDiv').length === 1;
}

/**
 * Instantiates and renders igv.js widget on the page
 */
function initializeIgv() {
  var igvContainer, igvOptions, tracks, genome, genesTrack, bamTracks,
    genesTrackName, genes, locus;

  // Bail if already displayed or not signed in
  if (igvIsDisplayed() || accessToken === null) return;

  delete igv.browser;

  if (bamsToViewInIgv.includes(bamAndBaiFiles[0]) === false) {
    bamsToViewInIgv.push(bamAndBaiFiles[0]);
  }

  igvContainer = document.getElementById('igv-container');

  genes = $('.queried-gene');
  locus = (genes.length === 0) ? ['myc'] : [genes.first().text()];

  genome = bamsToViewInIgv[0].genomeAssembly;
  genesTrackName = 'Genes | ' + bamsToViewInIgv[0].genomeAnnotation.name;
  genesTrack = getGenesTrack(genome, genesTrackName);
  bamTracks = getBamTracks();
  tracks = [genesTrack].concat(bamTracks);

  igvOptions = {genome: genome, locus: locus, tracks: tracks};

  igv.createBrowser(igvContainer, igvOptions);

  // Log igv.js initialization in Google Analytics
  ga('send', 'event', 'igv', 'initialize');
}

$(document).on('click', '#genome-tab-nav > a', function(event) {
  if (typeof bamAndBaiFiles !== 'undefined') {
    initializeIgv();
  }
});

$(document).ready(function() {

  // Bail if on a page without genome visualization support
  if (typeof accessToken === 'undefined') return;

  if (window.location.hash === '#genome-tab') {
    $('#study-visualize-nav > a').click();

    // Reload igv if refreshing, but not upon clicking back button in sign-in
    if (accessToken !== null) $('#genome-tab-nav > a').click();
  }

  var signedInViaGenomeTab = localStorage.getItem('signed-in-via-genome-tab');
  if (signedInViaGenomeTab === 'true') {
    ga('send', 'event', 'genome', 'sign_in_end_success');

    // Remove usage analysis token
    localStorage.removeItem('signed-in-via-genome-tab');

    // Load igv
    $('#study-visualize-nav > a').click();
    $('#genome-tab-nav > a').click();
  }

  if (accessToken === null) {
    $('#genome-tab-nav')
      .attr('title', 'Click to sign in; only authenticated users can visualize genomes')
      .attr('data-toogle', 'tooltip');
  }
});