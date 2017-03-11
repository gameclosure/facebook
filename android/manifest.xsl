<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:android="http://schemas.android.com/apk/res/android">
	<xsl:template match="node()|@*">
		<xsl:copy>
			<xsl:apply-templates select="node()|@*"/>
		</xsl:copy>
	</xsl:template>

	<xsl:param name="facebook.facebookAppID" />
	<xsl:param name="facebook.facebookDisplayName" />

	<xsl:output indent="yes" />
	<xsl:template match="comment()" />

	<xsl:template match="meta-data[@android:name='FACEBOOK_APP_ID']">
		<meta-data android:name="FACEBOOK_APP_ID" android:value="\ {$facebook.facebookAppID}"/>
	</xsl:template>

	<xsl:template match="meta-data[@android:name='FACEBOOK_DISPLAY_NAME']">
		<meta-data android:name="FACEBOOK_DISPLAY_NAME" android:value="{$facebook.facebookDisplayName}"/>
	</xsl:template>

	<xsl:template match="meta-data[@android:name='com.facebook.sdk.ApplicationId']">
		<meta-data android:name="com.facebook.sdk.ApplicationId" android:value="\ {$facebook.facebookAppID}"/>
	</xsl:template>

	<xsl:template match="meta-data[@android:name='com.facebook.sdk.ApplicationName']">
		<meta-data android:name="com.facebook.sdk.ApplicationName" android:value="\ {$facebook.facebookDisplayName}"/>
	</xsl:template>

	<xsl:template match="activity[@android:name='com.facebook.LoginActivity']">
		<activity android:name="com.facebook.LoginActivity"
			android:theme="@android:style/Theme.Translucent.NoTitleBar"
			android:label="{$facebook.facebookDisplayName}" />
	</xsl:template>

	<xsl:template match="provider[@android:name='com.facebook.FacebookContentProvider']">
		<xsl:if test="$facebook.facebookAppID">
			<provider
				android:authorities="com.facebook.app.FacebookContentProvider{$facebook.facebookAppID}"
				android:name="com.facebook.FacebookContentProvider"
				android:exported="true"/>
		</xsl:if>
	</xsl:template>

	<xsl:template match="@*|node()">
		<xsl:copy>
			<xsl:apply-templates select="@*|node()" />
		</xsl:copy>
	</xsl:template>
</xsl:stylesheet>
