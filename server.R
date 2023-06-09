library(leaflet)
library(RColorBrewer)
library(scales)
library(lattice)
library(dplyr)
library(shinyalert)
library(here)
library(tidyverse)
library(janitor)
library(sf)
library(uuid)
source('global.R')
source('preprocessing_geo.R')

function(input, output, session) {
  
  # Need to cut out last row for now... type issues reading kml
  sampling = sampling %>% rowwise() %>% mutate(geometry = coord_list[[id]]$centroid) %>% st_as_sf()
  sampling_filtered = reactiveValues(vals = sampling)
  
  sample_labels <- sprintf(
    "<div id = 'sample-label'><strong>%s</strong><br/>(Click to expand detailed view)</div>",
    sampling$project_module) %>%
    lapply(htmltools::HTML)
  
  ## Interactive Map ###########################################
  
  # Create the map
  output$map <- renderLeaflet({
    leaflet() %>%
      addTiles(urlTemplate = "https://server.arcgisonline.com/ArcGIS/rest/services/Ocean/World_Ocean_Base/MapServer/tile/{z}/{y}/{x}", options = tileOptions(minZoom = 6, maxZoom = 16)) %>%
      addTiles(urlTemplate = "https://server.arcgisonline.com/ArcGIS/rest/services/Ocean/World_Ocean_Reference/MapServer/tile/{z}/{y}/{x}", options = tileOptions(minZoom = 6, maxZoom = 16)) %>% 
      setView(lng = -118.42, lat = 33.59, zoom = 9)
  })
  
  # Toggle dumpsite polygons
  observeEvent(input$showDumpsite, {
    leafletProxy("map") %>% clearPopups()
    event <- input$showDumpsite
    
    if (is.null(event) || !event) {
      leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "dumpsites")
      return()
    }
    
    leafletProxy("map") %>% clearPopups() %>% 
      addPolygons(
        data = dumpsites,
        group = "dumpsites",
        fill = FALSE,
        color = "#FF0000",
        weight = 4,
        label = ~site_label
      )
  })
  
  # Build icon for samples
  mag_glass = makeIcon(
    iconUrl = "https://cdn-icons-png.flaticon.com/512/49/49116.png",
    iconWidth = 25,
    iconHeight = 25
  )
  
  # Toggle cluster
  observeEvent(input$cluster, {
    leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "detailed")
    event <- input$cluster

    if (is.null(event) || !event) {
      leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "sample_objects") %>% 
        addMarkers(
          group = "sample_objects",
          data = sampling_filtered$vals,
          layerId = ~id,
          icon = mag_glass,
          label = ~sample_labels,
          labelOptions = list(direction = "top")
        )
      return()
    }
    
    
    leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "sample_objects") %>% 
      addMarkers(
        group = "sample_objects",
        data = sampling_filtered$vals,
        layerId = ~id,
        icon = mag_glass,
        label = ~sample_labels,
        labelOptions = list(direction = "top"),
        clusterOptions = markerClusterOptions(showCoverageOnHover = FALSE, freezeAtZoom = 10)
      )
  })
  
  # Clear detailed markers on map click
  observeEvent(input$map_click, {
    click <- input$map_click
    leafletProxy("map") %>% clearGroup("detailed")
  })
  
  
  # Filter selections
  observe({
    leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "detailed")
    if (is.null(input$parameters) && is.null(input$institutions)) {
      leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "sample_objects")
      return()
    }
    
    event <- input$parameters
    sampling_filtered$vals = sampling
    if (is.null(event)){
      sampling_filtered$vals = sampling_filtered$vals
    } else {
      sampling_filtered$vals = sampling %>%
        filter(any(str_split(tolower(parameters_measured), "\\, |\\,|\\; ,| \\(")[[1]] %in% event))
    }
    
    event <- input$institutions
    if (is.null(event)){
      sampling_filtered$vals = sampling_filtered$vals
    } else {
      sampling_filtered$vals = sampling_filtered$vals %>%
        filter(any(str_split(tolower(institution), "\\, |\\,|\\; ")[[1]] %in% event))
    }
    
    leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "sample_objects") %>% 
      addMarkers(
        group = "sample_objects",
        data = sampling_filtered$vals,
        layerId = ~id,
        icon = mag_glass,
        label = ~sample_labels,
        labelOptions = list(direction = "top"),
      )
  })
  
  # This observer is responsible for onMouseclick popups
  observe({
    leafletProxy("map") %>% clearPopups() %>% clearGroup(group = "detailed")
    event <- input$map_marker_click
    if (is.null(event) || is.null(event$id))
      return()
    
    isolate({
      showSampleData(event$id, event$lat, event$lng)
    })
    
    sample <- coord_list[[event$id]]
    sample_bounds = as.vector(sample$geo %>% st_combine() %>% st_bbox())
    
    leafletProxy("map") %>% # clearGroup(group = "sample_objects") %>% clear primary markers? how to get back after?
      addMarkers(data = sample$geo, group = "detailed")
      #TODO fix warning Input to asJSON(keep_vec_names=TRUE) is a named vector.
      
    
    if (st_geometry_type(sample$chull) == "POLYGON") {
      leafletProxy("map") %>%
        addPolygons(
          data = sample$chull,
          group = "detailed",
          color = "#000",
          fillColor = "#FFF",
          opacity = 0.5,
          weight = 1
        ) %>% 
        flyToBounds(lng2 = sample_bounds[1], lat2 = sample_bounds[2], lng1 = sample_bounds[3], lat1 = sample_bounds[4], options = c(animate = TRUE))
    }
  })
  
  showSampleData <- function(marker_id, lat, lng) {
    if (is.null(id)) {
      return()
    }
    
    selectedSample <- sampling %>% filter(id == marker_id)
    
    content <- as.character(tagList(
      tags$h5("PIs:", selectedSample$p_is),
      tags$strong(HTML(sprintf("Institutions: %s", selectedSample$institution))), tags$hr(),
      
      tags$strong(HTML("Overview:")), tags$br(),
      sprintf("%s", selectedSample$overview), tags$br(), tags$br(),
      sprintf("Parameters: %s", selectedSample$parameters_measured), tags$hr(),
      
      tags$strong(HTML(sprintf("Sampling Dates: %s - %s", selectedSample$sampling_date_start, selectedSample$sampling_date_end))), tags$br(),
      sprintf("Collection Status: %s", selectedSample$status_collection), tags$br(),
      sprintf("Analysis Status: %s", selectedSample$status_analysis)
    ))
    
    leafletProxy("map") %>% addPopups(lng, lat, content, layerId = id, options = popupOptions(closeOnClick = TRUE, keepInView = TRUE))
  }
  
  
  ## Welcome message ##############################
  shinyalert(
    html = T,
    title = "Southern California Offshore DDT Dumpsite\nSampling and Research Portal",
    text = "Use this portal to explore the sampling and research efforts that are planned, in progress, and have been conducted around the DDT chemical dumpsites in the Southern California Bight.<hr>Website in development. For more information, go to <a href='https://scripps.ucsd.edu/ddtcoastaldumpsite'>https://scripps.ucsd.edu/ddtcoastaldumpsite</a>.",
    type = "",
    size = "m",
    imageUrl = "https://sccoos.org/wp-content/uploads/2022/05/SCCOOS_logo-01.png", #https://s2020.s3.amazonaws.com/media/logo-scripps-ucsd-dark.png", #
    imageWidth = 500,
    imageHeight = 60
  )
  
  ## Learn more page #############################
  # iFrame ui element
  output$frame <- renderUI({
    tags$iframe(src="https://storymaps.arcgis.com/stories/a99fb3a26dc643c6b577f4811817b534", frameborder = "no", style="height: 100vh;", allowfullscreen = "TRUE", allow="geolocation")
  })
  
  
  ### testing
  # seattle_geojson <- list(
  #   type = "Feature",
  #   geometry = list(
  #     type = "MultiPoint",
  #     coordinates = list(c(33.5765, -118.43484), c(33.57361, -118.43607))
  #   ),
  #   properties = list(
  #     name = "Test1",
  #     PIs = "test2",
  #     # You can inline styles if you want
  #     style = list(
  #       fillColor = "yellow",
  #       weight = 2,
  #       color = "#000000"
  #     )
  #   ),
  #   id = "test1"
  # )
  ##########
}